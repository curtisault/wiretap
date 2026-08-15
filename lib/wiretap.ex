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

  alias Wiretap.SessionManager
  alias Wiretap.Snapshot

  @doc """
  Starts a capture session on `pubsub`: polls the registry on an interval,
  diffs, and records `:joined`/`:left` events until stopped or a budget
  expires it.

  Options: `:name`, `:interval_ms` (default 1000), `:max_events` (default
  1000), `:max_duration_ms` (default 60_000).

      {:ok, session} = Wiretap.watch(MyApp.PubSub, interval_ms: 250)
      # ... exercise the app ...
      Wiretap.events(session)
      Wiretap.stop(session)
  """
  @spec watch(Snapshot.pubsub(), keyword()) :: {:ok, String.t()} | {:error, term()}
  defdelegate watch(pubsub, opts \\ []), to: SessionManager

  @doc "Stops a running session, tearing down everything it attached."
  @spec stop(String.t()) :: :ok | {:error, :not_running}
  defdelegate stop(session), to: SessionManager, as: :stop_session

  @doc "All sessions this node has seen (running and finished), newest first."
  @spec sessions() :: [Wiretap.Session.t()]
  defdelegate sessions(), to: SessionManager

  @doc "Captured events for a session, oldest first. Works for finished sessions too."
  @spec events(String.t()) :: [Wiretap.Event.t()]
  defdelegate events(session), to: SessionManager

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
