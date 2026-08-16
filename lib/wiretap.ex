defmodule Wiretap do
  @moduledoc """
  See who's listening on your Phoenix.PubSub topics — live.

  v0.1 exposes layer 1: point-in-time registry snapshots, usable headless from
  iex and ExUnit. The functions here delegate to `Wiretap.Snapshot`; pass the
  name of a `Phoenix.PubSub` instance (e.g. `MyApp.PubSub`).

      Wiretap.topics(MyApp.PubSub)
      #=> ["airwaves:announcements", "station:jazz"]

      Wiretap.subscribers(MyApp.PubSub, "station:jazz")
      #=> [#PID<0.456.0>]
  """

  alias Wiretap.Snapshot

  @doc "Snapshot of every subscription: topic → sorted subscriber pids."
  @spec snapshot(Snapshot.pubsub()) :: Snapshot.t()
  defdelegate snapshot(pubsub), to: Snapshot, as: :take

  @doc "All topics with at least one subscriber, sorted."
  @spec topics(Snapshot.pubsub()) :: [Snapshot.topic()]
  defdelegate topics(pubsub), to: Snapshot

  @doc "Sorted pids subscribed to `topic` right now."
  @spec subscribers(Snapshot.pubsub(), Snapshot.topic()) :: [pid()]
  defdelegate subscribers(pubsub, topic), to: Snapshot
end
