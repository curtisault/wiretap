defmodule Wiretap.Snapshotter do
  @moduledoc """
  Per-session poller: takes registry snapshots on the session's interval,
  diffs consecutive snapshots, and pushes `:joined` / `:left` events
  (source `:snapshot` — the approximate kind) to the Collector.

  The first snapshot is a silent baseline: subscriptions that existed before
  the session started do not fan a wave of fake joins into the timeline.

  Every pid seen in a snapshot is monitored (§4.3). When a subscriber
  disappears from a topic *because it died*, the departure is pushed as
  `kind: :left_by_death, source: :monitor` with the exit reason — the
  leak-vs-crash distinction, one release before call tracing. A pid whose
  registry entries outlive its `:DOWN` by a poll (cleanup is asynchronous
  and per-partition) keeps its death record until every entry is gone.
  """

  use GenServer

  alias Wiretap.Collector
  alias Wiretap.Snapshot

  @doc false
  def start_link(session) do
    GenServer.start_link(__MODULE__, session, name: via(session.name))
  end

  defp via(session_name), do: {:via, Registry, {Wiretap.Registry, {session_name, :snapshotter}}}

  @impl true
  def init(session) do
    baseline = Snapshot.take(session.pubsub)
    schedule(session.interval_ms)

    {:ok,
     %{
       session: session,
       prev: baseline,
       monitors: sync_monitors(%{}, pids_in(baseline)),
       deaths: %{}
     }}
  end

  @impl true
  def handle_info(:poll, state) do
    %{session: session, prev: prev, deaths: deaths} = state
    current = Snapshot.take(session.pubsub)
    %{joined: joined, left: left} = Snapshot.diff(prev, current)

    for {topic, pid} <- joined do
      Collector.push(session.name, %{kind: :joined, source: :snapshot, topic: topic, pid: pid})
    end

    for {topic, pid} <- left do
      case deaths do
        %{^pid => reason} ->
          Collector.push(session.name, %{
            kind: :left_by_death,
            source: :monitor,
            topic: topic,
            pid: pid,
            meta: %{reason: reason}
          })

        _ ->
          Collector.push(session.name, %{kind: :left, source: :snapshot, topic: topic, pid: pid})
      end
    end

    current_pids = pids_in(current)
    schedule(session.interval_ms)

    {:noreply,
     %{
       state
       | prev: current,
         monitors: sync_monitors(state.monitors, current_pids),
         deaths: Map.filter(deaths, fn {pid, _reason} -> MapSet.member?(current_pids, pid) end)
     }}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    {:noreply,
     %{
       state
       | monitors: Map.delete(state.monitors, pid),
         deaths: Map.put(state.deaths, pid, reason)
     }}
  end

  defp pids_in(snapshot) do
    snapshot |> Map.values() |> List.flatten() |> MapSet.new()
  end

  # Monitor pids newly present in the snapshot; drop monitors for pids that
  # left cleanly (dead pids already vanished from the map via :DOWN).
  defp sync_monitors(monitors, current_pids) do
    monitors =
      Enum.reduce(current_pids, monitors, fn pid, acc ->
        Map.put_new_lazy(acc, pid, fn -> Process.monitor(pid) end)
      end)

    {keep, drop} = Map.split_with(monitors, fn {pid, _ref} -> MapSet.member?(current_pids, pid) end)

    for {_pid, ref} <- drop, do: Process.demonitor(ref, [:flush])

    keep
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :poll, interval_ms)
end
