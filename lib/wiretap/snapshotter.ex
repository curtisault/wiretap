defmodule Wiretap.Snapshotter do
  @moduledoc """
  Per-session poller: takes registry snapshots on the session's interval,
  diffs consecutive snapshots, and pushes synthetic `:joined` / `:left`
  events (source `:snapshot` — the approximate kind) to the Collector.

  The first snapshot is a silent baseline: subscriptions that existed before
  the session started do not fan a wave of fake joins into the timeline.
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
    {:ok, %{session: session, prev: baseline}}
  end

  @impl true
  def handle_info(:poll, %{session: session, prev: prev} = state) do
    current = Snapshot.take(session.pubsub)
    %{joined: joined, left: left} = Snapshot.diff(prev, current)

    for {topic, pid} <- joined do
      Collector.push(session.name, %{kind: :joined, source: :snapshot, topic: topic, pid: pid})
    end

    for {topic, pid} <- left do
      Collector.push(session.name, %{kind: :left, source: :snapshot, topic: topic, pid: pid})
    end

    schedule(session.interval_ms)
    {:noreply, %{state | prev: current}}
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :poll, interval_ms)
end
