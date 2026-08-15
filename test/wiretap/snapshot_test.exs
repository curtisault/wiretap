defmodule Wiretap.SnapshotTest do
  use ExUnit.Case, async: true

  alias Wiretap.Snapshot

  defmodule TestServer do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}
  end

  defp start_pubsub(opts \\ []) do
    name = :"pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, [name: name] ++ opts})
    name
  end

  defp subscribe(pubsub, topic, extras \\ fn -> :ok end) do
    parent = self()

    pid =
      spawn(fn ->
        extras.()
        :ok = Phoenix.PubSub.subscribe(pubsub, topic)
        send(parent, {:ready, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:ready, ^pid}
    pid
  end

  describe "take/1" do
    test "groups subscribers by topic with sorted pids" do
      pubsub = start_pubsub()
      jazz1 = subscribe(pubsub, "station:jazz")
      jazz2 = subscribe(pubsub, "station:jazz")
      news = subscribe(pubsub, "station:news")

      assert Snapshot.take(pubsub) == %{
               "station:jazz" => Enum.sort([jazz1, jazz2]),
               "station:news" => [news]
             }
    end

    test "returns an empty map for an idle registry" do
      assert Snapshot.take(start_pubsub()) == %{}
    end

    test "is correct on a partitioned registry" do
      pubsub = start_pubsub(pool_size: 4)
      pids = for n <- 1..20, do: subscribe(pubsub, "station:#{rem(n, 5)}")

      snapshot = Snapshot.take(pubsub)
      assert map_size(snapshot) == 5
      assert snapshot |> Map.values() |> List.flatten() |> Enum.sort() == Enum.sort(pids)
    end
  end

  describe "topics/1 and subscribers/2" do
    test "topics are sorted, subscribers are per-topic" do
      pubsub = start_pubsub()
      news = subscribe(pubsub, "station:news")
      _jazz = subscribe(pubsub, "station:jazz")

      assert Snapshot.topics(pubsub) == ["station:jazz", "station:news"]
      assert Snapshot.subscribers(pubsub, "station:news") == [news]
      assert Snapshot.subscribers(pubsub, "station:empty") == []
    end
  end

  describe "diff/2" do
    test "detects joins, leaves, and whole-topic transitions" do
      pid_a = self()
      pid_b = spawn(fn -> :ok end)

      old = %{"station:jazz" => [pid_a], "station:news" => [pid_a, pid_b]}
      new = %{"station:jazz" => [pid_a, pid_b], "station:sports" => [pid_a]}

      %{joined: joined, left: left} = Snapshot.diff(old, new)

      assert Enum.sort(joined) == Enum.sort([{"station:jazz", pid_b}, {"station:sports", pid_a}])
      assert Enum.sort(left) == Enum.sort([{"station:news", pid_a}, {"station:news", pid_b}])
    end

    test "identical snapshots diff to nothing" do
      snapshot = %{"station:jazz" => [self()]}
      assert Snapshot.diff(snapshot, snapshot) == %{joined: [], left: []}
    end

    test "sees real unsubscribe and death through take/1" do
      pubsub = start_pubsub()
      stayer = subscribe(pubsub, "station:jazz")
      leaver = subscribe(pubsub, "station:jazz")

      before = Snapshot.take(pubsub)
      ref = Process.monitor(leaver)
      send(leaver, :stop)
      assert_receive {:DOWN, ^ref, :process, ^leaver, _}
      # registry cleanup on death is asynchronous
      Process.sleep(50)

      assert Snapshot.diff(before, Snapshot.take(pubsub)) == %{
               joined: [],
               left: [{"station:jazz", leaver}]
             }

      assert Snapshot.subscribers(pubsub, "station:jazz") == [stayer]
    end
  end

  describe "probe/1" do
    test "accepts a real phoenix_pubsub registry, idle or busy" do
      pubsub = start_pubsub()
      assert Snapshot.probe(pubsub) == :ok

      subscribe(pubsub, "station:jazz")
      assert Snapshot.probe(pubsub) == :ok
    end

    test "reports a missing registry" do
      assert Snapshot.probe(:no_such_registry) == {:error, :no_registry}
    end

    test "rejects a registry with non-binary keys" do
      reg = :"weird_registry_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :duplicate, name: reg})
      {:ok, _} = Registry.register(reg, {:not, :a, :binary}, nil)

      assert Snapshot.probe(reg) == {:error, :unrecognized_shape}
    end
  end

  describe "label/1" do
    test "prefers the registered name" do
      name = :"labeled_#{System.unique_integer([:positive])}"
      pid = subscribe(start_pubsub(), "station:jazz", fn -> Process.register(self(), name) end)

      assert Snapshot.label(pid) == inspect(name)
    end

    test "uses a process label when set" do
      pid = subscribe(start_pubsub(), "station:jazz", fn -> :proc_lib.set_label("tuned-in listener") end)

      assert Snapshot.label(pid) == "tuned-in listener"
    end

    test "falls back to the $initial_call module for OTP processes" do
      pid = start_supervised!({TestServer, []})
      assert Snapshot.label(pid) == inspect(TestServer)
    end

    test "falls back to inspect/1 for raw and dead pids" do
      raw = spawn(fn -> Process.sleep(:infinity) end)
      assert Snapshot.label(raw) == inspect(raw)

      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}
      assert Snapshot.label(dead) == inspect(dead)
    end
  end
end
