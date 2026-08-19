defmodule Wiretap.SeqTracerTest do
  # The seq_trace system tracer is a node-wide singleton.
  use ExUnit.Case, async: false

  setup do
    pubsub = :"pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})
    %{pubsub: pubsub}
  end

  # Accumulates silently: a subscriber that forwarded messages DURING the
  # collect window would itself appear in the tree (it inherits the token —
  # that is causality working). Flush after the trace instead.
  defp subscriber(pubsub, topic) do
    parent = self()

    pid =
      spawn(fn ->
        :ok = Phoenix.PubSub.subscribe(pubsub, topic)
        send(parent, {:ready, self()})

        loop = fn loop, acc ->
          receive do
            {:flush, from} ->
              send(from, {:msgs, self(), Enum.reverse(acc)})
              loop.(loop, [])

            :stop ->
              :ok

            msg ->
              loop.(loop, [msg | acc])
          end
        end

        loop.(loop, [])
      end)

    assert_receive {:ready, ^pid}
    pid
  end

  defp flush(pid) do
    send(pid, {:flush, self()})

    receive do
      {:msgs, ^pid, msgs} -> msgs
    after
      1_000 -> []
    end
  end

  test "direct fan-out: one hop per subscriber, labeled, causally ordered", %{pubsub: pubsub} do
    subs = for _ <- 1..3, do: subscriber(pubsub, "station:jazz")

    assert {:ok, tree} =
             Wiretap.trace_broadcast(pubsub, "station:jazz", {:now_playing, "Take Five"})

    assert tree.topic == "station:jazz"
    assert tree.message_preview =~ "Take Five"
    assert length(tree.hops) == 3
    assert Enum.sort(Enum.map(tree.hops, & &1.to)) == Enum.sort(subs)
    assert Enum.all?(tree.hops, &(&1.depth == 1))
    assert Enum.all?(tree.hops, &is_binary(&1.to_label))
    assert Enum.all?(tree.hops, &(&1.delta_us >= 0))
    assert tree.hops == Enum.sort_by(tree.hops, & &1.serial)

    # the broadcast really was delivered
    for pid <- subs, do: assert({:now_playing, "Take Five"} in flush(pid))
  end

  test "relays produce second-order hops; a dying relay's exit signal is not a hop",
       %{pubsub: pubsub} do
    final = subscriber(pubsub, "station:final")
    parent = self()

    relay =
      spawn(fn ->
        :ok = Phoenix.PubSub.subscribe(pubsub, "station:first")
        send(parent, {:ready, self()})

        receive do
          msg -> Phoenix.PubSub.broadcast(pubsub, "station:final", {:relayed, msg})
        end
      end)

    assert_receive {:ready, ^relay}

    assert {:ok, tree} = Wiretap.trace_broadcast(pubsub, "station:first", :hop_one)

    assert [first, second] = tree.hops
    assert first.depth == 1 and first.to == relay
    assert second.depth == 2 and second.from == relay and second.to == final
    assert second.message_preview =~ "relayed"
    refute Enum.any?(tree.hops, &(&1.message_preview =~ "EXIT"))
  end

  test "an unwired topic returns an empty tree — the 'is it even wired?' answer",
       %{pubsub: pubsub} do
    assert {:ok, %{hops: []}} = Wiretap.trace_broadcast(pubsub, "station:nobody", :ping)
  end

  test "a foreign system tracer is detected, refused, and left untouched", %{pubsub: pubsub} do
    foreign = spawn(fn -> Process.sleep(:infinity) end)
    false = :seq_trace.set_system_tracer(foreign)
    on_exit(fn -> :seq_trace.set_system_tracer(false) end)

    assert Wiretap.trace_broadcast(pubsub, "station:jazz", :ping) == {:error, :foreign_tracer}
    assert :seq_trace.get_system_tracer() == foreign

    :seq_trace.set_system_tracer(false)
    Process.exit(foreign, :kill)
  end

  test "concurrent requests serialize and each gets its own tree", %{pubsub: pubsub} do
    subscriber(pubsub, "station:a")
    subscriber(pubsub, "station:b")

    [a, b] =
      Task.await_many(
        [
          Task.async(fn -> Wiretap.trace_broadcast(pubsub, "station:a", :ping_a) end),
          Task.async(fn -> Wiretap.trace_broadcast(pubsub, "station:b", :ping_b) end)
        ],
        10_000
      )

    assert {:ok, %{topic: "station:a", hops: [%{message_preview: ":ping_a"}]}} = a
    assert {:ok, %{topic: "station:b", hops: [%{message_preview: ":ping_b"}]}} = b

    # the singleton slot is released
    assert :seq_trace.get_system_tracer() == false
  end
end
