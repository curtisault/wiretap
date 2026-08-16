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
    manager = Process.whereis(Wiretap.SessionManager)

    tab =
      :ets.new(:wiretap_events, [
        :set,
        :protected,
        {:read_concurrency, true},
        {:heir, manager, session.name}
      ])

    {:ok, %{tab: tab, seq: 0, session: session}}
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

    captured = seq + 1

    if captured == session.max_events do
      send(Wiretap.SessionManager, {:budget_exhausted, session.name, :max_events})
    end

    {:noreply, %{state | seq: captured}}
  end
end
