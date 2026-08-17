# Spike P1 — layer-3 mechanics for v0.4 (see ../discovery.md).
#
# Part 1: per-pid :receive tracing through OTP trace sessions — the Wiretap
#         panel's mechanism (3a). Also: can :trace.recv/3 match specs filter
#         messages in the VM, and does the payload arrive in the trace message?
# Part 2: :sys.install on an OTP process (capture messages + state), removal,
#         and the graceful-refusal path for non-OTP pids (4.2).
# Part 3: seq_trace across a RELAY: stamped broadcast → subscriber A re-broadcasts
#         → subscriber B. The multi-hop causal tree is the Broadcast Trace core.
#
# Run from the project root:  mix run docs/payloads/spikes/p1_receive_sys_seq.exs

defmodule SpikeP1 do
  def check(label, result), do: IO.puts("  #{if result, do: "OK  ", else: "FAIL"}  #{label}")

  def collector do
    spawn(fn ->
      Process.flag(:message_queue_data, :off_heap)
      collect([])
    end)
  end

  defp collect(acc) do
    receive do
      {:get, from} ->
        send(from, {:events, Enum.reverse(acc)})
        collect(acc)

      msg ->
        collect([msg | acc])
    end
  end

  def events(pid) do
    send(pid, {:get, self()})

    receive do
      {:events, events} -> events
    after
      2_000 -> :timeout
    end
  end

  def subscriber(pubsub, topic) do
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

    receive do
      {:ready, ^pid} -> pid
    end

    pid
  end

  def part1_receive_tracing(pubsub) do
    IO.puts("Part 1 — per-pid :receive tracing via trace sessions")
    receiver = collector()
    session = :trace.session_create(:p1_recv, receiver, [])

    tapped = subscriber(pubsub, "station:jazz")
    untapped = subscriber(pubsub, "station:jazz")

    1 = :trace.process(session, tapped, true, [:receive])

    Phoenix.PubSub.broadcast(pubsub, "station:jazz", {:now_playing, "Take Five"})
    Process.sleep(100)

    events = events(receiver)

    received =
      for {:trace, pid, :receive, msg} <- events, do: {pid, msg}

    check("exactly one receive event (only the tapped pid)", length(received) == 1)

    case received do
      [{pid, msg}] ->
        check("tapped pid is the subscriber", pid == tapped)
        check("full payload arrives in the trace message", msg == {:now_playing, "Take Five"})
        check("untapped subscriber generated nothing", pid != untapped)

      _ ->
        check("payload shape", false)
    end

    # recv match specs: filter in the VM on message shape {Node, Sender, Msg}
    receiver2 = collector()
    session2 = :trace.session_create(:p1_recv_ms, receiver2, [])
    tapped2 = subscriber(pubsub, "station:jazz")
    1 = :trace.process(session2, tapped2, true, [:receive])

    ms = [{[:_, :_, {:now_playing, :_}], [], []}]

    recv_result =
      try do
        {:ok, :trace.recv(session2, ms, [])}
      rescue
        e -> {:error, e}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case recv_result do
      {:ok, _} ->
        Phoenix.PubSub.broadcast(pubsub, "station:jazz", {:now_playing, "So What"})
        Phoenix.PubSub.broadcast(pubsub, "station:jazz", {:squawk, 1234})
        Process.sleep(100)

        msgs = for {:trace, _pid, :receive, msg} <- events(receiver2), do: msg

        check(
          "recv match spec filters in the VM (only :now_playing arrived: #{inspect(msgs)})",
          msgs == [{:now_playing, "So What"}]
        )

      {:error, reason} ->
        IO.puts("  info: :trace.recv/3 unavailable or rejected: #{inspect(reason)}")
        check("recv match spec support (see info above)", false)
    end

    :trace.session_destroy(session)
    :trace.session_destroy(session2)
  end

  def part2_sys_install(pubsub) do
    IO.puts("Part 2 — :sys.install capture, removal, and non-OTP refusal")

    {:ok, agent} = Agent.start(fn -> %{tracks: 0} end)
    parent = self()

    debug_fun = fn state, event, _extra ->
      send(parent, {:sys_event, event})
      state
    end

    :ok = :sys.install(agent, {debug_fun, :no_state})
    Agent.update(agent, fn s -> %{s | tracks: s.tracks + 1} end)

    got_event =
      receive do
        {:sys_event, _} -> true
      after
        1_000 -> false
      end

    check(":sys debug fun sees the agent's messages", got_event)

    state_preview = :sys.get_state(agent)
    check(":sys.get_state reads live state (#{inspect(state_preview)})", state_preview.tracks == 1)

    # one update fires several system events; drain them before removing
    flush = fn flush ->
      receive do
        {:sys_event, _} -> flush.(flush)
      after
        100 -> :ok
      end
    end

    flush.(flush)

    :ok = :sys.remove(agent, debug_fun)
    Agent.update(agent, fn s -> %{s | tracks: s.tracks + 1} end)

    silent =
      receive do
        {:sys_event, _} -> false
      after
        200 -> true
      end

    check("after :sys.remove the hook is gone", silent)

    # non-OTP pid: refusal must be graceful and fast
    raw = subscriber(pubsub, "station:raw")

    otp_compliant? = fn pid ->
      case Process.info(pid, :dictionary) do
        nil -> false
        {:dictionary, dict} -> List.keymember?(dict, :"$initial_call", 0)
      end
    end

    check("pdict $initial_call detects non-OTP pids without calling :sys", not otp_compliant?.(raw))
    check("…and correctly passes OTP pids", otp_compliant?.(agent))

    refusal =
      try do
        :sys.install(raw, {debug_fun, :no_state}, 150)
        :installed_anyway
      catch
        :exit, {:timeout, _} -> :timed_out
        :exit, reason -> {:exit, elem(reason, 0)}
      end

    check("blind :sys.install on a raw pid only times out (#{inspect(refusal)}) — detect first", refusal == :timed_out)

    Agent.stop(agent)
  end

  def part3_relay_tree(pubsub) do
    IO.puts("Part 3 — seq_trace across a relay: multi-hop causal tree")
    tracer = collector()
    :seq_trace.set_system_tracer(tracer)
    parent = self()

    final = subscriber(pubsub, "station:final")

    relay =
      spawn(fn ->
        :ok = Phoenix.PubSub.subscribe(pubsub, "station:first")
        send(parent, {:ready, self()})

        receive do
          msg -> Phoenix.PubSub.broadcast(pubsub, "station:final", {:relayed, msg})
        end
      end)

    receive do
      {:ready, ^relay} -> :ok
    end

    stamper =
      spawn(fn ->
        :seq_trace.set_token(:label, {:wiretap, :tree})
        :seq_trace.set_token(:send, true)
        :seq_trace.set_token(:timestamp, true)
        :ok = Phoenix.PubSub.broadcast(pubsub, "station:first", :hop_one)
        :seq_trace.set_token([])
        send(parent, :stamped)
      end)

    receive do
      :stamped -> :ok
    end

    Process.sleep(200)

    raw =
      for {:seq_trace, {:wiretap, :tree}, {:send, serial, from, to, msg}, _ts} <- events(tracer),
          do: %{serial: serial, from: from, to: to, msg: msg}

    # Spike finding: exit signals PROPAGATE the token and surface as :send
    # events (the relay's {:EXIT, _, :normal} to its Registry link). Tree
    # assembly must classify system signals out of the delivery tree.
    {exits, hops} = Enum.split_with(raw, &match?({:EXIT, _, _}, &1.msg))

    check("exit signals also carry the token — classify them out (saw #{length(exits)})",
      length(exits) == 1)

    check("two delivery hops captured (broadcast + relay)", length(hops) == 2)

    by_serial = Enum.sort_by(hops, & &1.serial)

    case by_serial do
      [first, second] ->
        check("hop 1: stamper → relay", first.from == stamper and first.to == relay)
        check("hop 2: relay → final subscriber (token propagated through the relay)",
          second.from == relay and second.to == final and match?({:relayed, _}, second.msg))

        check("serials establish causal order", first.serial < second.serial)

      _ ->
        check("tree shape", false)
    end

    :seq_trace.set_system_tracer(false)
  end
end

IO.puts("Spike P1 — layer-3 mechanics on OTP #{:erlang.system_info(:otp_release)}\n")

pubsub = :spike_p1_pubsub
{:ok, _} = Supervisor.start_link([{Phoenix.PubSub, name: pubsub}], strategy: :one_for_one)

SpikeP1.part1_receive_tracing(pubsub)
SpikeP1.part2_sys_install(pubsub)
SpikeP1.part3_relay_tree(pubsub)
