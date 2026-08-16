defmodule Wiretap.SessionManager do
  @moduledoc """
  Owns session lifecycle and the teardown guarantees of the safety contract
  (§8.2): everything a session attached is removed on stop, expiry, or crash,
  and sessions never auto-resume — on (re)start, any orphaned session
  processes are swept.

  Emits the telemetry taxonomy from discovery A3: session start/stop (span
  convention), budget exhaustion, and registry incompatibility. Runs the
  `Wiretap.Snapshot.probe/1` shape check before arming a session and refuses
  loudly (log + telemetry + error return) when layer 1 cannot be trusted.

  The session index (`#{inspect(:wiretap_sessions)}` ETS) and each session's
  event table are world-readable; reads never call this process.
  """

  use GenServer

  alias Wiretap.Collector
  alias Wiretap.Session
  alias Wiretap.Snapshot
  alias Wiretap.TelemetryBridge

  require Logger

  @index :wiretap_sessions

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Starts a capture session on `pubsub`. See `Wiretap.watch/2` for options."
  @spec watch(atom(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def watch(pubsub, opts \\ []), do: GenServer.call(__MODULE__, {:watch, pubsub, opts})

  @doc "Stops a running session, tearing down everything it attached."
  @spec stop_session(String.t()) :: :ok | {:error, :not_running}
  def stop_session(name), do: GenServer.call(__MODULE__, {:stop, name})

  @doc "All sessions this node has seen (running and finished), newest first."
  @spec sessions() :: [Session.t()]
  def sessions do
    @index
    |> :ets.tab2list()
    |> Enum.map(fn {_name, session, _tab} -> session end)
    |> Enum.sort_by(& &1.started_at, :desc)
  end

  @doc """
  Captured events for a session, in capture order. Pure ETS read; works for
  finished sessions too. Raises `ArgumentError` for an unknown session.
  """
  @spec events(String.t()) :: [Wiretap.Event.t()]
  def events(name) do
    case :ets.lookup(@index, name) do
      [{^name, _session, tab}] -> Collector.read(tab)
      [] -> raise ArgumentError, "unknown wiretap session: #{inspect(name)}"
    end
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    :ets.new(@index, [:named_table, :set, :protected, {:read_concurrency, true}])

    # Sessions never auto-resume: if a previous manager crashed, its session
    # processes are orphans — sweep them.
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Wiretap.SessionSupervisor) do
      DynamicSupervisor.terminate_child(Wiretap.SessionSupervisor, pid)
    end

    {:ok, %{sessions: %{}}}
  end

  @impl true
  def handle_call({:watch, pubsub, opts}, _from, state) do
    session = Session.new(pubsub, opts)

    with :ok <- TelemetryBridge.validate(session.telemetry),
         :ok <- probe_loudly(pubsub),
         {:ok, sup} <- start_session_tree(session) do
      tab = Collector.table(session.name)
      ref = Process.monitor(sup)
      timer = Process.send_after(self(), {:expire, session.name}, session.max_duration_ms)
      :ets.insert(@index, {session.name, session, tab})
      :ok = TelemetryBridge.attach(session)

      :telemetry.execute(
        [:wiretap, :session, :start],
        %{system_time: System.system_time()},
        %{
          session: session.name,
          budgets: %{max_events: session.max_events, max_duration_ms: session.max_duration_ms},
          attachments: attachments(session)
        }
      )

      entry = %{session: session, sup: sup, ref: ref, timer: timer, tab: tab}
      {:reply, {:ok, session.name}, put_in(state.sessions[session.name], entry)}
    else
      {:error, {:shutdown, {:failed_to_start_child, _child, {:log_file, reason}}}} ->
        {:reply, {:error, {:log_file, reason}}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop, name}, _from, state) do
    case state.sessions do
      %{^name => entry} -> {:reply, :ok, finish(state, name, entry, :manual)}
      _ -> {:reply, {:error, :not_running}, state}
    end
  end

  @impl true
  def handle_info({:expire, name}, state) do
    case state.sessions do
      %{^name => entry} ->
        emit_budget_exhausted(entry, :max_duration, entry.session.max_duration_ms)
        {:noreply, finish(state, name, entry, :expired)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:budget_exhausted, name, :max_events}, state) do
    case state.sessions do
      %{^name => entry} ->
        emit_budget_exhausted(entry, :max_events, entry.session.max_events)
        {:noreply, finish(state, name, entry, :expired)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.sessions, fn {_name, entry} -> entry.ref == ref end) do
      {name, entry} -> {:noreply, finish(state, name, entry, :crash, terminate?: false)}
      nil -> {:noreply, state}
    end
  end

  # Ring-buffer tables name this process as their heir so events outlive
  # their Collector; nothing to do on transfer.
  def handle_info({:"ETS-TRANSFER", _tab, _from, _session_name}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    for {name, entry} <- state.sessions, do: finish(state, name, entry, :manual)
    :ok
  end

  defp probe_loudly(pubsub) do
    case Snapshot.probe(pubsub) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Wiretap: layer 1 unavailable for #{inspect(pubsub)} (#{inspect(reason)}); " <>
            "refusing to start session"
        )

        :telemetry.execute([:wiretap, :registry, :incompatible], %{}, %{
          pubsub: pubsub,
          reason: reason
        })

        {:error, reason}
    end
  end

  defp start_session_tree(session) do
    spec = %{
      id: {:wiretap_session, session.name},
      start:
        {Supervisor, :start_link,
         [
           [{Collector, session}, {Wiretap.Snapshotter, session}],
           [strategy: :one_for_all, max_restarts: 0]
         ]},
      restart: :temporary,
      type: :supervisor
    }

    DynamicSupervisor.start_child(Wiretap.SessionSupervisor, spec)
  end

  defp attachments(session) do
    [:snapshot] ++
      if(session.telemetry == [], do: [], else: [:telemetry]) ++
      if(session.log_file, do: [:log_file], else: [])
  end

  defp finish(state, name, entry, reason, opts \\ []) do
    Process.cancel_timer(entry.timer)
    Process.demonitor(entry.ref, [:flush])
    TelemetryBridge.detach(name)

    events_captured = captured_count(entry, reason)

    if Keyword.get(opts, :terminate?, true) do
      DynamicSupervisor.terminate_child(Wiretap.SessionSupervisor, entry.sup)
    end

    status = status_for(reason)
    :ets.insert(@index, {name, %{entry.session | status: status}, entry.tab})

    :telemetry.execute(
      [:wiretap, :session, :stop],
      %{
        duration: System.monotonic_time() - entry.session.started_at,
        events_captured: events_captured
      },
      %{session: name, reason: reason}
    )

    %{state | sessions: Map.delete(state.sessions, name)}
  end

  # On a crash the Collector is already gone — fall back to counting the
  # retained events in the (inherited) table.
  defp captured_count(entry, :crash), do: length(Collector.read(entry.tab))
  defp captured_count(entry, _reason), do: Collector.count(entry.session.name)

  defp status_for(:manual), do: :stopped
  defp status_for(:expired), do: :expired
  defp status_for(:crash), do: :crashed

  defp emit_budget_exhausted(entry, bound, limit) do
    :telemetry.execute(
      [:wiretap, :budget, :exhausted],
      %{events_captured: length(Collector.read(entry.tab))},
      %{session: entry.session.name, bound: bound, limit: limit}
    )
  end
end
