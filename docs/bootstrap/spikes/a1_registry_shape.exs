# Spike A1 — registry-shape matrix (see ../discovery.md, main discovery doc §A1).
#
# Verifies that the Wiretap layer-1 snapshot mechanism — Registry.select/2 with the
# topic/pid match spec — returns correct topic → subscriber groupings across
# phoenix_pubsub versions and start options (pool_size / registry_size partitioning,
# group_by), and that unsubscribe and subscriber death both remove entries.
#
# Run outside mix (uses Mix.install):
#   PUBSUB_VERSION=2.2.0 elixir docs/bootstrap/spikes/a1_registry_shape.exs

version = System.fetch_env!("PUBSUB_VERSION")
Mix.install([{:phoenix_pubsub, version}])

defmodule SpikeA1 do
  @select_spec [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}]

  def snapshot(name) do
    name
    |> Registry.select(@select_spec)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {topic, pids} -> {topic, Enum.sort(pids)} end)
  end

  def run(version, opts) do
    name = :"spike_#{System.unique_integer([:positive])}"
    spec = {Phoenix.PubSub, [name: name] ++ opts}

    case Supervisor.start_link([spec], strategy: :one_for_one) do
      {:ok, sup} ->
        try do
          report(version, opts, exercise(name))
        after
          Supervisor.stop(sup)
        end
    end
  rescue
    e -> report(version, opts, [{"start/run", "ERROR: #{Exception.message(e)}"}])
  catch
    kind, reason -> report(version, opts, [{"start/run", "ERROR: #{kind} #{inspect(reason)}"}])
  end

  defp exercise(name) do
    parent = self()

    subs =
      for i <- 1..6 do
        pid =
          spawn(fn ->
            topic = "t:#{rem(i, 3)}"
            send(parent, {:ready, self(), topic, Phoenix.PubSub.subscribe(name, topic)})
            subscriber_loop(parent, name, topic)
          end)

        receive do
          {:ready, ^pid, topic, :ok} -> {pid, topic}
          {:ready, ^pid, _topic, other} -> throw({:subscribe_failed, other})
        after
          1_000 -> throw(:subscribe_timeout)
        end
      end

    expected =
      subs
      |> Enum.group_by(fn {_pid, topic} -> topic end, fn {pid, _topic} -> pid end)
      |> Map.new(fn {topic, pids} -> {topic, Enum.sort(pids)} end)

    c1 = {"select groups match subscriptions", snapshot(name) == expected}

    :ok = Phoenix.PubSub.broadcast(name, "t:0", :ping)
    t0 = expected["t:0"]

    got =
      for _ <- t0 do
        receive do
          {:msg, pid, :ping} -> pid
        after
          1_000 -> :timeout
        end
      end

    stray =
      receive do
        {:msg, _pid, :ping} -> true
      after
        100 -> false
      end

    c2 = {"broadcast fans out via the same table", Enum.sort(got) == t0 and not stray}

    [{u_pid, u_topic} | _] = subs
    send(u_pid, :unsubscribe)

    receive do
      {:unsubscribed, ^u_pid} -> :ok
    after
      1_000 -> throw(:unsubscribe_timeout)
    end

    c3 = {"unsubscribe removes entry", snapshot(name)[u_topic] == expected[u_topic] -- [u_pid]}

    {d_pid, d_topic} = Enum.at(subs, 1)
    ref = Process.monitor(d_pid)
    send(d_pid, :die)

    receive do
      {:DOWN, ^ref, :process, ^d_pid, _} -> :ok
    end

    # Registry cleanup on death is asynchronous; give it a beat.
    Process.sleep(50)
    c4 = {"death removes entry", d_pid not in Map.get(snapshot(name), d_topic, [])}

    [c1, c2, c3, c4]
  end

  defp subscriber_loop(parent, name, topic) do
    receive do
      :unsubscribe ->
        Phoenix.PubSub.unsubscribe(name, topic)
        send(parent, {:unsubscribed, self()})
        subscriber_loop(parent, name, topic)

      :die ->
        :ok

      msg ->
        send(parent, {:msg, self(), msg})
        subscriber_loop(parent, name, topic)
    end
  end

  defp report(version, opts, checks) do
    IO.puts("phoenix_pubsub #{version}  opts=#{inspect(opts)}")

    Enum.each(checks, fn
      {label, true} -> IO.puts("  OK    #{label}")
      {label, false} -> IO.puts("  FAIL  #{label}")
      {label, other} -> IO.puts("  ????  #{label}: #{other}")
    end)
  end
end

configs = [
  [],
  [pool_size: 1],
  [pool_size: 4],
  [registry_size: 8],
  [group_by: :pid],
  [group_by: :key],
  [group_by: :key, registry_size: 4]
]

Enum.each(configs, &SpikeA1.run(version, &1))
