defmodule Wiretap.SessionManagerTest do
  use ExUnit.Case, async: true

  alias Wiretap.Event

  @telemetry_events [
    [:wiretap, :session, :start],
    [:wiretap, :session, :stop],
    [:wiretap, :budget, :exhausted],
    [:wiretap, :registry, :incompatible]
  ]

  setup do
    handler_id = "test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      @telemetry_events,
      fn event, measurements, meta, test_pid ->
        send(test_pid, {:telemetry, event, measurements, meta})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp start_pubsub do
    name = :"pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: name})
    name
  end

  defp subscribe(pubsub, topic) do
    parent = self()

    pid =
      spawn(fn ->
        :ok = Phoenix.PubSub.subscribe(pubsub, topic)
        send(parent, {:ready, self()})
        subscriber_loop(parent, pubsub, topic)
      end)

    assert_receive {:ready, ^pid}
    pid
  end

  defp subscriber_loop(parent, pubsub, topic) do
    receive do
      :unsubscribe ->
        :ok = Phoenix.PubSub.unsubscribe(pubsub, topic)
        send(parent, {:unsubscribed, self()})
        subscriber_loop(parent, pubsub, topic)

      :stop ->
        :ok
    end
  end

  defp eventually(fun, tries \\ 100) do
    fun.()
  rescue
    e in [ExUnit.AssertionError] ->
      if tries > 0 do
        Process.sleep(20)
        eventually(fun, tries - 1)
      else
        reraise e, __STACKTRACE__
      end
  end

  defp session_status(name) do
    Enum.find_value(Wiretap.sessions(), fn s -> s.name == name && s.status end)
  end

  test "watch captures joined and left events with labels and honesty source" do
    pubsub = start_pubsub()
    {:ok, session} = Wiretap.watch(pubsub, interval_ms: 25)
    assert_receive {:telemetry, [:wiretap, :session, :start], _, %{attachments: [:snapshot]}}

    listener = subscribe(pubsub, "station:jazz")

    eventually(fn ->
      assert %Event{} =
               joined =
               Enum.find(
                 Wiretap.events(session),
                 &(&1.kind == :joined and &1.pid == listener)
               )

      assert joined.topic == "station:jazz"
      assert joined.source == :snapshot
      assert joined.session == session
      assert is_binary(joined.pid_label)
    end)

    send(listener, :unsubscribe)
    assert_receive {:unsubscribed, ^listener}

    eventually(fn ->
      assert %Event{source: :snapshot} =
               Enum.find(
                 Wiretap.events(session),
                 &(&1.kind == :left and &1.pid == listener and &1.topic == "station:jazz")
               )
    end)

    :ok = Wiretap.stop(session)
  end

  test "a subscriber that dies is recorded as left_by_death with the exit reason" do
    pubsub = start_pubsub()
    # baseline subscriber: monitors must cover pids seen before the session too
    early = subscribe(pubsub, "station:news")
    {:ok, session} = Wiretap.watch(pubsub, interval_ms: 25)
    late = subscribe(pubsub, "station:jazz")

    eventually(fn ->
      assert Enum.any?(Wiretap.events(session), &(&1.kind == :joined and &1.pid == late))
    end)

    send(late, :stop)
    Process.exit(early, :kill)

    eventually(fn ->
      events = Wiretap.events(session)

      assert %Event{source: :monitor, meta: %{reason: :normal}} =
               Enum.find(events, &(&1.kind == :left_by_death and &1.pid == late))

      assert %Event{source: :monitor, meta: %{reason: :killed}, topic: "station:news"} =
               Enum.find(events, &(&1.kind == :left_by_death and &1.pid == early))
    end)

    :ok = Wiretap.stop(session)
  end

  test "pre-existing subscriptions are a silent baseline, not fake joins" do
    pubsub = start_pubsub()
    _existing = subscribe(pubsub, "station:news")

    {:ok, session} = Wiretap.watch(pubsub, interval_ms: 25)
    Process.sleep(100)

    assert Wiretap.events(session) == []
    :ok = Wiretap.stop(session)
  end

  test "max_events budget expires the session and emits the alarm" do
    pubsub = start_pubsub()
    {:ok, session} = Wiretap.watch(pubsub, interval_ms: 10, max_events: 1)
    subscribe(pubsub, "station:jazz")

    eventually(fn -> assert session_status(session) == :expired end)

    assert_receive {:telemetry, [:wiretap, :budget, :exhausted], _, meta}
    assert %{session: ^session, bound: :max_events, limit: 1} = meta

    assert_receive {:telemetry, [:wiretap, :session, :stop], %{events_captured: 1},
                    %{session: ^session, reason: :expired}}
  end

  test "max_duration budget expires the session" do
    pubsub = start_pubsub()
    {:ok, session} = Wiretap.watch(pubsub, max_duration_ms: 50)

    eventually(fn -> assert session_status(session) == :expired end)

    assert_receive {:telemetry, [:wiretap, :budget, :exhausted], _, meta}
    assert %{session: ^session, bound: :max_duration, limit: 50} = meta
  end

  test "stop tears the session down; events remain readable afterwards" do
    pubsub = start_pubsub()
    {:ok, session} = Wiretap.watch(pubsub, interval_ms: 10)
    listener = subscribe(pubsub, "station:sports")

    eventually(fn -> assert Wiretap.events(session) != [] end)

    assert :ok = Wiretap.stop(session)
    assert Wiretap.stop(session) == {:error, :not_running}
    assert session_status(session) == :stopped
    assert_receive {:telemetry, [:wiretap, :session, :stop], _, %{session: ^session, reason: :manual}}

    # via-registrations are cleaned up asynchronously after process death
    eventually(fn ->
      assert [] = Registry.lookup(Wiretap.Registry, {session, :collector})
      assert [] = Registry.lookup(Wiretap.Registry, {session, :snapshotter})
    end)

    # the heir transfer keeps the ring buffer readable after teardown
    assert Enum.any?(Wiretap.events(session), &(&1.pid == listener))
  end

  test "a crashed session is torn down, marked, and reported" do
    pubsub = start_pubsub()
    {:ok, session} = Wiretap.watch(pubsub, interval_ms: 10)

    [{collector, _}] = Registry.lookup(Wiretap.Registry, {session, :collector})
    Process.exit(collector, :kill)

    eventually(fn -> assert session_status(session) == :crashed end)
    assert_receive {:telemetry, [:wiretap, :session, :stop], _, %{session: ^session, reason: :crash}}
    eventually(fn -> assert [] = Registry.lookup(Wiretap.Registry, {session, :snapshotter}) end)
  end

  test "refuses loudly when the registry fails the shape probe" do
    assert Wiretap.watch(:no_such_registry) == {:error, :no_registry}

    assert_receive {:telemetry, [:wiretap, :registry, :incompatible], _,
                    %{pubsub: :no_such_registry, reason: :no_registry}}
  end

  test "unknown session raises on events/1" do
    assert_raise ArgumentError, ~r/unknown wiretap session/, fn ->
      Wiretap.events("never-existed")
    end
  end
end
