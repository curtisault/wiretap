defmodule Wiretap.SysInspectorTest do
  use ExUnit.Case, async: true

  alias Wiretap.SysInspector

  defmodule Listener do
    @moduledoc false
    use GenServer

    def start(state), do: GenServer.start(__MODULE__, state)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_info(_msg, state), do: {:noreply, state}
  end

  defp raw_pid do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(pid, :stop) end)
    pid
  end

  defp flush_sys_events do
    receive do
      {:wiretap_sys_event, _, _} -> flush_sys_events()
    after
      150 -> :ok
    end
  end

  describe "peek/1" do
    test "reads an OTP process: state preview, chains, queue length" do
      {:ok, pid} = Listener.start(%{tracks: 3})

      assert {:ok, info} = SysInspector.peek(pid)
      assert info.pid == pid
      assert info.state_preview =~ "tracks: 3"
      assert {Listener, :init, 1} = info.initial_call
      assert is_integer(info.message_queue_len)
      # started by the test process: proc_lib records it as the ancestor
      assert info.ancestors != []
      assert Enum.all?(info.ancestors, &is_binary/1)

      GenServer.stop(pid)
    end

    test "refuses a raw spawn before any :sys call" do
      assert {:error, :not_otp_compliant} = SysInspector.peek(raw_pid())
    end

    test "refuses a dead pid" do
      {:ok, pid} = Listener.start(:whatever)
      GenServer.stop(pid)
      assert {:error, :not_alive} = SysInspector.peek(pid)
    end
  end

  describe "watch_messages/3 + stop_watching/2" do
    test "forwards :sys events for each message, with a readable description" do
      {:ok, pid} = Listener.start(:idle)

      assert {:ok, id} = SysInspector.watch_messages(pid, self())
      send(pid, {:now_playing, "Take Five"})

      assert_receive {:wiretap_sys_event, ^pid, event}
      assert SysInspector.describe_event(event) =~ "Take Five"

      SysInspector.stop_watching(pid, id)
      GenServer.stop(pid)
    end

    test "stop_watching removes the hook — later messages stay silent" do
      {:ok, pid} = Listener.start(:idle)
      {:ok, id} = SysInspector.watch_messages(pid, self())

      send(pid, :first)
      assert_receive {:wiretap_sys_event, ^pid, _}

      # one message fires several sys events (spike P1) — drain, then remove
      flush_sys_events()
      :ok = SysInspector.stop_watching(pid, id)

      send(pid, :second)
      refute_receive {:wiretap_sys_event, ^pid, _}, 200

      GenServer.stop(pid)
    end

    test "the cap self-removes the hook: max events forwarded, ever" do
      {:ok, pid} = Listener.start(:idle)
      {:ok, _id} = SysInspector.watch_messages(pid, self(), max: 1)

      send(pid, :one)
      send(pid, :two)
      send(pid, :three)

      assert_receive {:wiretap_sys_event, ^pid, _}
      refute_receive {:wiretap_sys_event, ^pid, _}, 200

      GenServer.stop(pid)
    end

    test "a dead receiver self-cleans without harming the process" do
      {:ok, pid} = Listener.start(:idle)

      receiver = spawn(fn -> :ok end)
      ref = Process.monitor(receiver)
      assert_receive {:DOWN, ^ref, :process, ^receiver, _}

      {:ok, _id} = SysInspector.watch_messages(pid, receiver)
      send(pid, :anything)

      # the hook noticed the dead receiver and removed itself; process unharmed
      assert Process.alive?(pid)
      assert {:ok, id2} = SysInspector.watch_messages(pid, self())
      send(pid, :again)
      assert_receive {:wiretap_sys_event, ^pid, _}

      SysInspector.stop_watching(pid, id2)
      GenServer.stop(pid)
    end

    test "refuses non-OTP pids without touching :sys" do
      assert {:error, :not_otp_compliant} = SysInspector.watch_messages(raw_pid(), self())
    end
  end

  describe "describe_event/1" do
    test "renders the common gen_server event shapes" do
      assert SysInspector.describe_event({:in, :ping}) =~ "in ◀ :ping"
      assert SysInspector.describe_event({:in, :ping, self()}) =~ "from"
      assert SysInspector.describe_event({:out, :pong, self()}) =~ "out ▶ :pong"
      assert SysInspector.describe_event({:noreply, :state}) == "→ noreply"
      assert SysInspector.describe_event(:weird) == ":weird"
    end
  end
end
