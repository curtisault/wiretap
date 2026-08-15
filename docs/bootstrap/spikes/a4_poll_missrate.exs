# Spike A4 — snapshot polling: miss rate and select cost (see ../discovery.md, main
# discovery doc §A4).
#
# Part 1: cost of the layer-1 snapshot (Registry.select + grouping) at ~10k
# subscriptions across 2k topics — informs whether ~1s (or faster) polling is cheap.
#
# Part 2: modal-style churn (subscribe, hold, unsubscribe, repeat) against a poller at
# 1000/250/100ms intervals, hold times 2000/500/100ms. Each episode uses a unique
# topic; an episode is "seen" if any poll observed it. Miss rate decides how honest
# the v0.2 snapshot-diff Timeline is, and the default poll interval.
#
# Run from the project root:  mix run docs/bootstrap/spikes/a4_poll_missrate.exs

defmodule SpikeA4 do
  @select_spec [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}]

  def select_cost do
    name = :spike_a4_cost
    {:ok, _sup} = Supervisor.start_link([{Phoenix.PubSub, name: name}], strategy: :one_for_one)
    parent = self()

    for i <- 1..10_000 do
      spawn(fn ->
        :ok = Phoenix.PubSub.subscribe(name, "station:#{rem(i, 2_000)}")
        send(parent, :ready)

        receive do
          :never -> :ok
        end
      end)
    end

    for _ <- 1..10_000 do
      receive do
        :ready -> :ok
      end
    end

    times =
      for _ <- 1..10 do
        {us, snap} = :timer.tc(fn -> snapshot(name) end)
        true = map_size(snap) == 2_000
        us
      end

    IO.puts("  10k subscriptions / 2k topics, select+group (10 runs):")
    IO.puts("  min #{Enum.min(times)}µs  avg #{div(Enum.sum(times), length(times))}µs  max #{Enum.max(times)}µs")
  end

  def miss_rate(interval_ms, hold_ms) do
    name = :"spike_a4_#{interval_ms}_#{hold_ms}"
    {:ok, sup} = Supervisor.start_link([{Phoenix.PubSub, name: name}], strategy: :one_for_one)
    parent = self()

    churners = for c <- 1..50, do: spawn(fn -> churn(name, parent, c, hold_ms, 0) end)
    poller = spawn(fn -> poll(name, parent, interval_ms, MapSet.new()) end)

    Process.sleep(6_000)
    Enum.each(churners, &Process.exit(&1, :kill))
    send(poller, :stop)

    seen =
      receive do
        {:seen, set} -> set
      end

    episodes = drain_episodes([])
    total = length(episodes)
    seen_count = Enum.count(episodes, &MapSet.member?(seen, &1))
    miss = if total > 0, do: Float.round(100 * (total - seen_count) / total, 1), else: 0.0
    IO.puts("  poll #{interval_ms}ms  hold ~#{hold_ms}ms   episodes #{total}   missed #{miss}%")
    Supervisor.stop(sup)
  end

  defp snapshot(name) do
    name
    |> Registry.select(@select_spec)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp churn(name, parent, c, hold_ms, ep) do
    topic = "churn:#{c}:#{ep}"
    :ok = Phoenix.PubSub.subscribe(name, topic)
    Process.sleep(jitter(hold_ms))
    :ok = Phoenix.PubSub.unsubscribe(name, topic)
    send(parent, {:episode, topic})
    Process.sleep(100)
    churn(name, parent, c, hold_ms, ep + 1)
  end

  # +/- 25% so episodes don't phase-lock with the poller
  defp jitter(ms), do: max(10, ms + :rand.uniform(div(ms, 2) + 1) - div(ms, 4))

  defp poll(name, parent, interval_ms, seen) do
    receive do
      :stop -> send(parent, {:seen, seen})
    after
      interval_ms ->
        topics = name |> Registry.select(@select_spec) |> Enum.map(&elem(&1, 0))
        poll(name, parent, interval_ms, Enum.into(topics, seen))
    end
  end

  defp drain_episodes(acc) do
    receive do
      {:episode, topic} -> drain_episodes([topic | acc])
    after
      0 -> acc
    end
  end
end

IO.puts("Spike A4 — part 1: Registry.select cost at scale")
SpikeA4.select_cost()

IO.puts("\nSpike A4 — part 2: poll miss rate (50 churners, 6s per cell, completed episodes only)")

for interval <- [1_000, 250, 100], hold <- [2_000, 500, 100] do
  SpikeA4.miss_rate(interval, hold)
end
