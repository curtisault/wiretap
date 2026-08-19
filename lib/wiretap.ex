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
  1000), `:max_duration_ms` (default 60_000), `:max_rate` (events/sec before
  auto-expiry, default 250), `:telemetry` (host telemetry event names to
  bridge into the timeline, e.g. `[[:my_app, :repo, :query]]`), `:log_file`
  (append captured events to this file — one grep-able line per event; add it
  to .gitignore), `:trace` (`true` or `[prefixes: ["station:"], mfas:
  [{MyApp.Stations, :subscribe, 1}]]` — layer-2 call tracing: exact
  joined/left events with caller attribution, requires OTP 27+), `:tap`
  (`[pid]` — layer 3a: capture everything the selected pids receive as
  `:message` events; per-pid, never groups), `:payloads`
  (`:off | bytes | :unlimited`, default 10_240 — preview size for tapped
  messages).

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

  @doc """
  Sends a seq-token-stamped `message` on `topic` and returns the delivery
  tree: every hop with causal order, per-hop timings, and labels — including
  second-order hops through relays. Injected by design: wiretap sends the
  broadcast itself (a token cannot be stamped into another process's sends).

      Wiretap.trace_broadcast(MyApp.PubSub, "orders:42", {:order_updated, 42})
      #=> {:ok, %{hops: [%{depth: 1, to_label: "LiveView", delta_us: 11, ...}, ...]}}

  An empty `hops` list answers "is it even wired?". Returns
  `{:error, :foreign_tracer}` if another tool owns the seq_trace tracer.
  """
  @spec trace_broadcast(Snapshot.pubsub(), Snapshot.topic(), term(), keyword()) ::
          {:ok, map()} | {:error, :foreign_tracer}
  defdelegate trace_broadcast(pubsub, topic, message, opts \\ []), to: Wiretap.SeqTracer

  @doc """
  Process Inspector (§4.2): reads one live OTP process through `:sys` —
  truncated state preview, `$ancestors`/`$callers` breadcrumbs, queue length.
  Non-OTP pids are detected before any `:sys` call and refused gracefully.

      Wiretap.peek(pid)
      #=> {:ok, %{label: "LiveView", state_preview: "%{...}", ancestors: [...]}}

  For the live message feed, see `Wiretap.SysInspector.watch_messages/3`.
  """
  @spec peek(pid()) :: {:ok, Wiretap.SysInspector.info()} | {:error, term()}
  defdelegate peek(pid), to: Wiretap.SysInspector

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
