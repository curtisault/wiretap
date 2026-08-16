defmodule Wiretap.SessionOptionsTest do
  # Probe tests toggle global compile config; keep this file synchronous.
  use ExUnit.Case, async: false

  alias Wiretap.Event

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

        receive do
          :stop -> :ok
        end
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

  describe "telemetry bridge" do
    test "bridged events land on the timeline with previews and detach on stop" do
      pubsub = start_pubsub()
      event_name = [:wiretap_test, :"ping_#{System.unique_integer([:positive])}"]
      {:ok, session} = Wiretap.watch(pubsub, telemetry: [event_name])

      :telemetry.execute(event_name, %{count: 1}, %{who: :me})

      eventually(fn ->
        assert %Event{source: :telemetry, topic: nil} =
                 bridged = Enum.find(Wiretap.events(session), &(&1.kind == :telemetry))

        assert bridged.meta.event == event_name
        assert bridged.payload_preview =~ "count"
        assert bridged.meta.metadata_preview =~ "who"
      end)

      captured = length(Wiretap.events(session))
      :ok = Wiretap.stop(session)

      :telemetry.execute(event_name, %{count: 2}, %{})
      Process.sleep(50)
      assert length(Wiretap.events(session)) == captured
    end

    test "an invalid :telemetry option is refused" do
      pubsub = start_pubsub()
      assert Wiretap.watch(pubsub, telemetry: [:not_a_list]) == {:error, :invalid_telemetry_option}
      assert Wiretap.watch(pubsub, telemetry: :nope) == {:error, :invalid_telemetry_option}
    end
  end

  describe "probe macro" do
    test "compiles to :ok and emits nothing when disabled (the default)" do
      pubsub = start_pubsub()
      {:ok, session} = Wiretap.watch(pubsub, interval_ms: 50)
      mod = compile_probe_module()

      assert mod.fire("station:jazz") == :ok
      Process.sleep(100)
      refute Enum.any?(Wiretap.events(session), &(&1.kind == :probe))
      :ok = Wiretap.stop(session)
    end

    test "emits to every running session when the host compiles with probes: true" do
      Application.put_env(:wiretap, :probes, true)
      on_exit(fn -> Application.delete_env(:wiretap, :probes) end)

      pubsub = start_pubsub()
      {:ok, session} = Wiretap.watch(pubsub, interval_ms: 50)
      mod = compile_probe_module()

      assert mod.fire("station:jazz") == :ok

      eventually(fn ->
        assert %Event{source: :probe, topic: "station:jazz", pid: pid} =
                 probe = Enum.find(Wiretap.events(session), &(&1.kind == :probe))

        assert probe.meta.label == "test probe"
        assert probe.meta.meta == %{k: 1}
        assert pid == self()
      end)

      :ok = Wiretap.stop(session)
    end
  end

  describe "file sink" do
    @tag :tmp_dir
    test "writes a header and one grep-able line per event, append-only", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "wiretap.log")
      pubsub = start_pubsub()

      {:ok, session} = Wiretap.watch(pubsub, interval_ms: 25, log_file: path)
      listener = subscribe(pubsub, "station:jazz")

      eventually(fn ->
        content = File.read!(path)
        assert content =~ "# wiretap session #{session} pubsub="
        assert content =~ "budgets=1000ev/60s"
        assert content =~ ~r/^\S+ #{session} joined station:jazz #{Regex.escape(inspect(listener))} .* source=snapshot$/m
      end)

      :ok = Wiretap.stop(session)

      # append-only: a second session on the same file keeps the first header
      {:ok, second} = Wiretap.watch(pubsub, interval_ms: 25, log_file: path)
      :ok = Wiretap.stop(second)
      content = File.read!(path)
      assert content =~ "# wiretap session #{session} "
      assert content =~ "# wiretap session #{second} "
    end

    test "an unwritable log_file refuses the session loudly" do
      pubsub = start_pubsub()

      assert {:error, {:log_file, :enoent}} =
               Wiretap.watch(pubsub, log_file: "/definitely/not/a/dir/wiretap.log")

      assert Enum.all?(Wiretap.sessions(), &(&1.pubsub != pubsub or &1.status != :running))
    end
  end

  defp compile_probe_module do
    mod = Module.concat([:"WiretapProbeHost#{System.unique_integer([:positive])}"])

    Code.compile_string("""
    defmodule #{mod} do
      require Wiretap.Probe

      def fire(topic), do: Wiretap.Probe.tap(topic, label: "test probe", meta: %{k: 1})
    end
    """)

    mod
  end
end
