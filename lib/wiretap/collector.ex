defmodule Wiretap.Collector do
  @moduledoc """
  Per-session event store: a bounded ETS ring buffer, owner-write world-read.

  The Collector process is the only writer; readers use `read/1` against the
  table directly and never call the GenServer. The table names the
  SessionManager as its heir, so captured events remain readable after the
  session (and this process) is gone — expired sessions stay inspectable.

  Capacity is #{10_000} events; older events are overwritten, newest win.
  """

  use GenServer

  alias Wiretap.Event
  alias Wiretap.Snapshot

  @capacity 10_000

  @doc false
  def start_link(session) do
    GenServer.start_link(__MODULE__, session, name: via(session.name))
  end

  @doc "Appends an event (async). `attrs` is a map of `Wiretap.Event` fields sans seq/at/session."
  @spec push(String.t(), map()) :: :ok
  def push(session_name, attrs) do
    GenServer.cast(via(session_name), {:push, attrs})
  end

  @doc "The session's ETS table id, for registering in the session index."
  @spec table(String.t()) :: :ets.tid()
  def table(session_name), do: GenServer.call(via(session_name), :table)

  @doc "Number of events captured so far (monotonic, may exceed retained capacity)."
  @spec count(String.t()) :: non_neg_integer()
  def count(session_name), do: GenServer.call(via(session_name), :count)

  @doc "Reads all retained events from a session table, in capture order. Pure ETS read."
  @spec read(:ets.tid()) :: [Event.t()]
  def read(tab) do
    tab
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1.seq)
  end

  defp via(session_name), do: {:via, Registry, {Wiretap.Registry, {session_name, :collector}}}

  @impl true
  def init(session) do
    case open_log(session) do
      {:ok, log} ->
        manager = Process.whereis(Wiretap.SessionManager)

        tab =
          :ets.new(:wiretap_events, [
            :set,
            :protected,
            {:read_concurrency, true},
            {:heir, manager, session.name}
          ])

        {:ok, %{tab: tab, seq: 0, session: session, log: log}}

      {:error, reason} ->
        {:stop, {:log_file, reason}}
    end
  end

  # The file sink (discovery v0.2): append-only, one grep-able line per event,
  # session header on open. The device is linked to this process, so it closes
  # with the session.
  defp open_log(%{log_file: nil}), do: {:ok, nil}

  # The path is supplied by the host developer via watch/2 or app config —
  # never by web input — so traversal is not a concern here.
  # sobelow_skip ["Traversal.FileModule"]
  defp open_log(session) do
    with {:ok, device} <- File.open(session.log_file, [:append, :utf8]) do
      IO.write(device, header(session))
      {:ok, device}
    end
  end

  defp header(session) do
    started = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    "# wiretap session #{session.name} pubsub=#{inspect(session.pubsub)} " <>
      "budgets=#{session.max_events}ev/#{div(session.max_duration_ms, 1_000)}s " <>
      "started #{started}\n"
  end

  @impl true
  def handle_call(:table, _from, state), do: {:reply, state.tab, state}
  def handle_call(:count, _from, state), do: {:reply, state.seq, state}

  @impl true
  def handle_cast({:push, attrs}, state) do
    %{tab: tab, seq: seq, session: session} = state
    pid = attrs[:pid]

    event = %Event{
      seq: seq,
      at: System.system_time(:microsecond),
      kind: Map.fetch!(attrs, :kind),
      source: Map.fetch!(attrs, :source),
      topic: attrs[:topic],
      pid: pid,
      pid_label: pid && Snapshot.label(pid),
      payload_preview: attrs[:payload_preview],
      session: session.name,
      meta: Map.get(attrs, :meta, %{})
    }

    :ets.insert(tab, {rem(seq, @capacity), event})
    maybe_log(state.log, event)

    captured = seq + 1

    # UI nudge (§5): count only, never payloads. UIs coalesce and re-read ETS.
    Phoenix.PubSub.broadcast(
      Wiretap.PubSub,
      "wiretap:session:" <> session.name,
      {:wiretap_events, session.name, captured}
    )

    if captured == session.max_events do
      send(Wiretap.SessionManager, {:budget_exhausted, session.name, :max_events})
    end

    {:noreply, %{state | seq: captured}}
  end

  defp maybe_log(nil, _event), do: :ok

  defp maybe_log(device, event) do
    at = event.at |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()

    IO.write(device, [
      at,
      " ",
      event.session,
      " ",
      Atom.to_string(event.kind),
      " ",
      event.topic || "-",
      " ",
      if(event.pid, do: inspect(event.pid), else: "-"),
      " ",
      inspect(event.pid_label || "-"),
      " source=",
      Atom.to_string(event.source),
      meta_suffix(event.meta),
      payload_suffix(event.payload_preview),
      "\n"
    ])
  end

  defp meta_suffix(meta) when map_size(meta) == 0, do: ""
  defp meta_suffix(meta), do: " meta=" <> inspect(meta)

  defp payload_suffix(nil), do: ""
  defp payload_suffix(preview), do: " payload=" <> inspect(preview)
end
