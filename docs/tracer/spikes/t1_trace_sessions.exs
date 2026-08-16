# Spike T1 — call-trace mechanics for the v0.3 tracer (see ../discovery.md).
#
# Verifies, on real Phoenix.PubSub.subscribe/3 calls through OTP trace sessions:
#   1. match-spec topic-prefix filtering AT THE TRACE LAYER (binary_part guard) —
#      uninteresting calls must generate no trace messages at all (§3 L2 rule 2)
#   2. caller attribution via the {:caller} match-spec action — who called subscribe
#   3. coexistence: two independent sessions tracing the SAME MFA, both receive;
#      destroying one leaves the other intact (§8.3)
#   4. overhead: traced vs untraced subscribe/unsubscribe churn, and whether a
#      passive receiver keeps up (informs A5 receiver design + budget defaults)
#
# Run from the project root:  mix run docs/tracer/spikes/t1_trace_sessions.exs

defmodule SpikeT1 do
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

  def subscribe_from(pubsub, topic) do
    parent = self()

    pid =
      spawn(fn ->
        :ok = Phoenix.PubSub.subscribe(pubsub, topic)
        send(parent, {:done, self()})

        receive do
          :stop -> :ok
        end
      end)

    receive do
      {:done, ^pid} -> pid
    end
  end

  # Trace BOTH subscribe arities with :global (external calls only): the arity-2
  # default-args wrapper reaches subscribe/3 via a LOCAL call that global call
  # tracing never sees — and external-only tracing keeps {:caller} pointing at
  # the real caller instead of the wrapper, with no double-counting.
  # {:caller} asks the VM for the {M, F, A} that called subscribe.
  def arm_subscribe(session, prefix) do
    1 = :trace.function(session, {Phoenix.PubSub, :subscribe, 2}, match_spec(2, prefix), [:global])
    1 = :trace.function(session, {Phoenix.PubSub, :subscribe, 3}, match_spec(3, prefix), [:global])
    :trace.process(session, :all, true, [:call])
  end

  def match_spec(arity, prefix) do
    head = if arity == 2, do: [:_, :"$1"], else: [:_, :"$1", :_]

    [
      {head,
       [
         {:andalso, {:is_binary, :"$1"},
          {:==, {:binary_part, :"$1", 0, byte_size(prefix)}, prefix}}
       ], [{:message, {{:"$1", {:caller}}}}]}
    ]
  end

  def part1_filter_and_caller(pubsub) do
    IO.puts("Part 1 — match-spec prefix filter + {:caller} attribution")
    receiver = collector()
    session = :trace.session_create(:t1_filter, receiver, [])

    arm_subscribe(session, "station:")

    station = subscribe_from(pubsub, "station:jazz")
    _other = subscribe_from(pubsub, "atc:events")
    Process.sleep(100)

    events = events(receiver)

    calls =
      for {:trace, pid, :call, {Phoenix.PubSub, :subscribe, _}, message} <- events,
          do: {pid, message}

    check("exactly one trace message (the station: call; atc: filtered in the VM)", length(calls) == 1)

    case calls do
      [{pid, {topic, caller}}] ->
        check("traced pid is the subscriber", pid == station)
        check("topic captured via match spec (#{inspect(topic)})", topic == "station:jazz")
        check("caller attribution is an MFA (#{inspect(caller)})", match?({_m, _f, _a}, caller))

      _ ->
        check("payload shape {topic, caller}", false)
    end

    :trace.session_destroy(session)
  end

  def part2_coexistence(pubsub) do
    IO.puts("Part 2 — two sessions on the same MFA coexist; destroying one spares the other")
    receiver_a = collector()
    receiver_b = collector()
    session_a = :trace.session_create(:t1_a, receiver_a, [])
    session_b = :trace.session_create(:t1_b, receiver_b, [])

    for {session, _r} <- [{session_a, receiver_a}, {session_b, receiver_b}] do
      arm_subscribe(session, "station:")
    end

    subscribe_from(pubsub, "station:one")
    Process.sleep(100)

    count = fn r -> Enum.count(events(r), &match?({:trace, _, :call, _, _}, &1)) end
    check("session A saw the call", count.(receiver_a) == 1)
    check("session B saw the same call", count.(receiver_b) == 1)

    :trace.session_destroy(session_a)
    subscribe_from(pubsub, "station:two")
    Process.sleep(100)

    check("after destroying A, B still traces", count.(receiver_b) == 2)
    check("A is silent after destroy", count.(receiver_a) == 1)

    :trace.session_destroy(session_b)
  end

  def part3_overhead(pubsub) do
    IO.puts("Part 3 — overhead and receiver keep-up under churn")
    rounds = 5_000

    churn = fn ->
      parent = self()

      pid =
        spawn(fn ->
          for i <- 1..rounds do
            topic = "station:#{rem(i, 50)}"
            :ok = Phoenix.PubSub.subscribe(pubsub, topic)
            :ok = Phoenix.PubSub.unsubscribe(pubsub, topic)
          end

          send(parent, :done)
        end)

      {us, _} = :timer.tc(fn ->
        receive do
          :done -> :ok
        end
      end)

      _ = pid
      us
    end

    baseline_us = churn.()

    receiver = collector()
    session = :trace.session_create(:t1_bench, receiver, [])
    arm_subscribe(session, "station:")

    traced_us = churn.()
    Process.sleep(200)
    received = Enum.count(events(receiver), &match?({:trace, _, :call, _, _}, &1))
    :trace.session_destroy(session)

    overhead = Float.round(traced_us / max(baseline_us, 1), 2)

    IO.puts("  info: #{rounds} subscribe/unsubscribe rounds — baseline #{div(baseline_us, 1000)}ms, " <>
      "traced #{div(traced_us, 1000)}ms (#{overhead}x), " <>
      "#{received}/#{rounds} trace messages received (#{div(received * 1_000_000, max(traced_us, 1))} ev/s)")

    check("receiver kept up (all #{rounds} events)", received == rounds)
    check("overhead under 3x on a hot loop (#{overhead}x)", traced_us < baseline_us * 3)
  end

  def part4_untraced_cost(pubsub) do
    IO.puts("Part 4 — attached-but-quiet: non-matching traffic while armed")
    receiver = collector()
    session = :trace.session_create(:t1_quiet, receiver, [])
    arm_subscribe(session, "station:")

    for i <- 1..1_000, do: subscribe_from(pubsub, "quiet:#{i}") |> send(:stop)
    Process.sleep(100)

    check(
      "1000 non-matching subscribes produced zero trace messages",
      Enum.count(events(receiver), &match?({:trace, _, :call, _, _}, &1)) == 0
    )

    :trace.session_destroy(session)
  end
end

IO.puts("Spike T1 — trace sessions on OTP #{:erlang.system_info(:otp_release)}\n")

pubsub = :spike_t1_pubsub
{:ok, _} = Supervisor.start_link([{Phoenix.PubSub, name: pubsub}], strategy: :one_for_one)

SpikeT1.part1_filter_and_caller(pubsub)
SpikeT1.part2_coexistence(pubsub)
SpikeT1.part3_overhead(pubsub)
SpikeT1.part4_untraced_cost(pubsub)
