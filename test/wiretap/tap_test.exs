defmodule Wiretap.TapTest do
  use ExUnit.Case, async: true

  alias Wiretap.Event

  setup do
    pubsub = :"pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})
    %{pubsub: pubsub}
  end

  defp subscriber(pubsub, topic) do
    parent = self()

    pid =
      spawn(fn ->
        :ok = Phoenix.PubSub.subscribe(pubsub, topic)
        send(parent, {:ready, self()})

        loop = fn loop ->
          receive do
            :stop -> :ok
            _ -> loop.(loop)
          end
        end

        loop.(loop)
      end)

    assert_receive {:ready, ^pid}
    pid
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

  test "a tapped pid's received messages land as :message events with previews",
       %{pubsub: pubsub} do
    tapped = subscriber(pubsub, "station:jazz")
    untapped = subscriber(pubsub, "station:jazz")

    {:ok, session} = Wiretap.watch(pubsub, tap: [tapped], interval_ms: 50)
    Phoenix.PubSub.broadcast(pubsub, "station:jazz", {:now_playing, "Take Five"})

    eventually(fn ->
      assert %Event{source: :receive_trace, topic: nil} =
               message =
               Enum.find(Wiretap.events(session), &(&1.kind == :message and &1.pid == tapped))

      assert message.payload_preview =~ "Take Five"
    end)

    # only explicitly selected pids are tapped
    refute Enum.any?(Wiretap.events(session), &(&1.kind == :message and &1.pid == untapped))

    # tap-only sessions keep the snapshot pipeline: a new subscriber still joins
    late = subscriber(pubsub, "station:news")

    eventually(fn ->
      assert Enum.any?(
               Wiretap.events(session),
               &(&1.kind == :joined and &1.source == :snapshot and &1.pid == late)
             )
    end)

    :ok = Wiretap.stop(session)
  end

  test "the payloads knob: :off stores kind-only events; byte caps truncate",
       %{pubsub: pubsub} do
    tapped = subscriber(pubsub, "station:jazz")
    {:ok, off} = Wiretap.watch(pubsub, tap: [tapped], payloads: :off)
    Phoenix.PubSub.broadcast(pubsub, "station:jazz", {:secret, "do not store"})

    eventually(fn ->
      assert %Event{payload_preview: nil} =
               Enum.find(Wiretap.events(off), &(&1.kind == :message))
    end)

    :ok = Wiretap.stop(off)

    {:ok, capped} = Wiretap.watch(pubsub, tap: [tapped], payloads: 32)
    Phoenix.PubSub.broadcast(pubsub, "station:jazz", {:big, String.duplicate("x", 500)})

    eventually(fn ->
      assert %Event{payload_preview: preview} =
               Enum.find(Wiretap.events(capped), &(&1.kind == :message))

      assert String.ends_with?(preview, "…")
      assert byte_size(preview) <= 32 + byte_size("…")
    end)

    :ok = Wiretap.stop(capped)
  end

  test "tap events count toward budgets and carry the :tap attachment", %{pubsub: pubsub} do
    handler_id = "tap-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:wiretap, :session, :start],
      fn _e, _m, meta, pid -> send(pid, {:start_meta, meta}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    tapped = subscriber(pubsub, "station:jazz")
    {:ok, session} = Wiretap.watch(pubsub, tap: [tapped], max_events: 2, interval_ms: 5_000)

    assert_receive {:start_meta, %{session: ^session, attachments: attachments}}
    assert :tap in attachments

    for n <- 1..5, do: Phoenix.PubSub.broadcast(pubsub, "station:jazz", {:n, n})

    eventually(fn ->
      assert Enum.find(Wiretap.sessions(), &(&1.name == session)).status == :expired
    end)
  end

  test "invalid taps and payloads are refused", %{pubsub: pubsub} do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}

    assert Wiretap.watch(pubsub, tap: [dead]) == {:error, :invalid_tap_pid}
    assert Wiretap.watch(pubsub, tap: [:not_a_pid]) == {:error, :invalid_tap_pid}
    assert Wiretap.watch(pubsub, payloads: -1) == {:error, :invalid_payloads_option}
    assert Wiretap.watch(pubsub, payloads: "10kb") == {:error, :invalid_payloads_option}
  end

  test "trace and tap combine in one session", %{pubsub: pubsub} do
    tapped = subscriber(pubsub, "station:jazz")
    {:ok, session} = Wiretap.watch(pubsub, trace: true, tap: [tapped])

    late = subscriber(pubsub, "station:news")
    Phoenix.PubSub.broadcast(pubsub, "station:jazz", {:now_playing, "So What"})

    eventually(fn ->
      events = Wiretap.events(session)

      assert Enum.any?(events, &(&1.kind == :joined and &1.source == :trace and &1.pid == late))

      assert Enum.any?(
               events,
               &(&1.kind == :message and &1.pid == tapped and &1.payload_preview =~ "So What")
             )
    end)

    :ok = Wiretap.stop(session)
  end
end
