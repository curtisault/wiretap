defmodule Wiretap.TracerTest do
  use ExUnit.Case, async: true

  alias Wiretap.Event

  defmodule Wrapper do
    @moduledoc false
    def sub(pubsub, topic), do: Phoenix.PubSub.subscribe(pubsub, topic)
  end

  setup do
    handler_id = "tracer-test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [[:wiretap, :budget, :exhausted], [:wiretap, :session, :start]],
      fn event, measurements, meta, test_pid ->
        send(test_pid, {:telemetry, event, measurements, meta})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    pubsub = :"pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})
    %{pubsub: pubsub}
  end

  defp subscribe(pubsub, topic) do
    parent = self()

    pid =
      spawn(fn ->
        :ok = Phoenix.PubSub.subscribe(pubsub, topic)
        send(parent, {:ready, self()})
        loop(pubsub, parent)
      end)

    assert_receive {:ready, ^pid}
    pid
  end

  defp loop(pubsub, parent) do
    receive do
      {:unsubscribe, topic} ->
        :ok = Phoenix.PubSub.unsubscribe(pubsub, topic)
        send(parent, {:unsubscribed, self()})
        loop(pubsub, parent)

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

  test "traced sessions get exact joined/left with caller attribution, no snapshot duplicates",
       %{pubsub: pubsub} do
    {:ok, session} = Wiretap.watch(pubsub, trace: true, interval_ms: 50)

    assert_receive {:telemetry, [:wiretap, :session, :start], _, %{session: ^session, attachments: attachments}}

    assert :trace in attachments

    listener = subscribe(pubsub, "station:jazz")

    eventually(fn ->
      assert %Event{source: :trace, meta: %{caller: {_m, _f, _a}}} =
               Enum.find(
                 Wiretap.events(session),
                 &(&1.kind == :joined and &1.pid == listener and &1.topic == "station:jazz")
               )
    end)

    send(listener, {:unsubscribe, "station:jazz"})
    assert_receive {:unsubscribed, ^listener}

    eventually(fn ->
      assert %Event{source: :trace} =
               Enum.find(Wiretap.events(session), &(&1.kind == :left and &1.pid == listener))
    end)

    # let several snapshot polls pass: the diff must not add approximate twins
    Process.sleep(150)
    events = Wiretap.events(session)
    assert Enum.count(events, &(&1.kind == :joined and &1.pid == listener)) == 1
    assert Enum.count(events, &(&1.kind == :left and &1.pid == listener)) == 1
    assert Enum.all?(events, &(&1.source != :snapshot))

    :ok = Wiretap.stop(session)
  end

  test "topic prefixes filter at the trace layer", %{pubsub: pubsub} do
    {:ok, session} = Wiretap.watch(pubsub, trace: [prefixes: ["station:"]], interval_ms: 5_000)

    matching = subscribe(pubsub, "station:jazz")
    _other = subscribe(pubsub, "atc:events")

    eventually(fn ->
      assert Enum.any?(Wiretap.events(session), &(&1.pid == matching))
    end)

    topics = session |> Wiretap.events() |> Enum.map(& &1.topic) |> Enum.uniq()
    assert topics == ["station:jazz"]

    :ok = Wiretap.stop(session)
  end

  test "user-added wrapper MFAs produce :call events and attribute the inner subscribe",
       %{pubsub: pubsub} do
    {:ok, session} = Wiretap.watch(pubsub, trace: [mfas: [{Wrapper, :sub, 2}]])

    parent = self()

    caller =
      spawn(fn ->
        :ok = Wrapper.sub(pubsub, "station:jazz")
        send(parent, {:done, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:done, ^caller}

    eventually(fn ->
      events = Wiretap.events(session)

      assert %Event{kind: :call, source: :trace} =
               call = Enum.find(events, &(&1.kind == :call and &1.pid == caller))

      assert call.meta.mfa == {Wrapper, :sub, 2}
      assert call.payload_preview =~ "station:jazz"

      # the wrapper's inner call to subscribe/2 is traced too. It is a TAIL
      # call, so {:caller} skips the wrapper frame and attributes the
      # wrapper's own caller (this test module) — the deeper, truer answer.
      assert %Event{kind: :joined, meta: %{caller: {Wiretap.TracerTest, _f, _a}}} =
               Enum.find(events, &(&1.kind == :joined and &1.pid == caller))
    end)

    :ok = Wiretap.stop(session)
  end

  test "death still arrives as left_by_death while tracing", %{pubsub: pubsub} do
    {:ok, session} = Wiretap.watch(pubsub, trace: true, interval_ms: 25)
    listener = subscribe(pubsub, "station:jazz")

    eventually(fn ->
      assert Enum.any?(Wiretap.events(session), &(&1.kind == :joined and &1.pid == listener))
    end)

    send(listener, :stop)

    eventually(fn ->
      assert %Event{source: :monitor, meta: %{reason: :normal}} =
               Enum.find(Wiretap.events(session), &(&1.kind == :left_by_death and &1.pid == listener))
    end)

    :ok = Wiretap.stop(session)
  end

  test "the max_rate budget expires a hot session", %{pubsub: pubsub} do
    {:ok, session} = Wiretap.watch(pubsub, trace: true, max_rate: 5, interval_ms: 5_000)

    spawn(fn ->
      for i <- 1..30, do: Phoenix.PubSub.subscribe(pubsub, "station:hot-#{i}")
    end)

    assert_receive {:telemetry, [:wiretap, :budget, :exhausted], _, %{session: ^session, bound: :max_rate, limit: 5}},
                   2_000

    eventually(fn ->
      assert Enum.find(Wiretap.sessions(), &(&1.name == session)).status == :expired
    end)
  end

  test "stop tears the tracer down and events cease", %{pubsub: pubsub} do
    {:ok, session} = Wiretap.watch(pubsub, trace: true, interval_ms: 5_000)
    subscribe(pubsub, "station:one")

    eventually(fn -> assert Wiretap.events(session) != [] end)
    :ok = Wiretap.stop(session)

    eventually(fn ->
      assert [] = Registry.lookup(Wiretap.Registry, {session, :tracer})
    end)

    captured = length(Wiretap.events(session))
    subscribe(pubsub, "station:two")
    Process.sleep(100)
    assert length(Wiretap.events(session)) == captured
  end

  test "unknown wrapper MFAs refuse the session", %{pubsub: pubsub} do
    assert Wiretap.watch(pubsub, trace: [mfas: [{No.Such.Module, :f, 1}]]) ==
             {:error, :invalid_trace_mfa}

    assert Wiretap.watch(pubsub, trace: [mfas: [:not_an_mfa]]) == {:error, :invalid_trace_mfa}
  end
end
