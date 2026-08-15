# Spike A6 — seq_trace semantics under the OTP 27+ trace-session world (see
# ../discovery.md, main discovery doc §A6). Gates the v0.4 Broadcast Trace design.
#
# Verifies:
#   1. the seq_trace system tracer is a per-node singleton (single slot, last set
#      wins) and a foreign tracer is detectable via get_system_tracer/0
#   2. a seq token stamped before Phoenix.PubSub.broadcast/3 propagates to every
#      subscriber delivery, with timestamps (the fan-out tree data source)
#   3. no events flow once the token is reset (zero idle footprint)
#   4. seq_trace and a :trace.session_create session can observe the same process
#      simultaneously without clobbering each other
#
# Run from the project root:  mix run docs/bootstrap/spikes/a6_seq_trace.exs

defmodule SpikeA6 do
  def check(label, result), do: IO.puts("  #{if result, do: "OK  ", else: "FAIL"}  #{label}")

  def collector do
    spawn(fn -> collect([]) end)
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
      1_000 -> :timeout
    end
  end

  def part1_singleton do
    IO.puts("Part 1 — system tracer is a singleton, foreign tracer detectable")
    a = collector()
    b = collector()

    initial = :seq_trace.get_system_tracer()
    check("no system tracer initially (got #{inspect(initial)})", initial == false)

    :seq_trace.set_system_tracer(a)
    check("get_system_tracer sees tracer A", :seq_trace.get_system_tracer() == a)

    old = :seq_trace.set_system_tracer(b)
    check("setting B returns A (single slot, last set wins)", old == a)
    check("get_system_tracer now sees B — foreign-tracer detection works", :seq_trace.get_system_tracer() == b)

    :seq_trace.set_system_tracer(false)

    seqish =
      :trace.module_info(:exports)
      |> Enum.filter(fn {name, _arity} -> name |> Atom.to_string() |> String.contains?("se") end)

    IO.puts("  info: :trace exports possibly related to seq/system tracing: #{inspect(seqish)}")
  end

  def part2_fanout do
    IO.puts("Part 2 — token propagates through Phoenix.PubSub.broadcast to every subscriber")
    name = :spike_a6_ps
    {:ok, _sup} = Supervisor.start_link([{Phoenix.PubSub, name: name}], strategy: :one_for_one)
    tracer = collector()
    :seq_trace.set_system_tracer(tracer)
    parent = self()

    subs =
      for _ <- 1..5 do
        pid =
          spawn(fn ->
            :ok = Phoenix.PubSub.subscribe(name, "st:demo")
            send(parent, {:ready, self()})

            receive do
              _ -> :ok
            end
          end)

        receive do
          {:ready, ^pid} -> pid
        end
      end

    stamper =
      spawn(fn ->
        :seq_trace.set_token(:label, {:wiretap, 1})
        :seq_trace.set_token(:send, true)
        :seq_trace.set_token(:timestamp, true)
        :ok = Phoenix.PubSub.broadcast(name, "st:demo", :payload)
        :seq_trace.set_token([])
        send(parent, {:stamped, self()})
      end)

    receive do
      {:stamped, ^stamper} -> :ok
    end

    Process.sleep(100)
    events = events(tracer)

    sends =
      for {:seq_trace, {:wiretap, 1}, {:send, _serial, from, to, :payload}, ts} <- events,
          do: {from, to, ts}

    check("one :send event per subscriber (got #{length(sends)}/5)", length(sends) == 5)
    check("all subscriber pids covered", Enum.sort(Enum.map(sends, &elem(&1, 1))) == Enum.sort(subs))
    check("all sends attributed to the stamping pid", Enum.all?(sends, fn {from, _, _} -> from == stamper end))
    check("per-hop timestamps present", Enum.all?(sends, fn {_, _, ts} -> is_tuple(ts) end))

    # 3. token reset → silence
    quiet =
      spawn(fn ->
        :ok = Phoenix.PubSub.broadcast(name, "st:demo", :unstamped)
        send(parent, :quiet_done)
      end)

    _ = quiet

    receive do
      :quiet_done -> :ok
    end

    Process.sleep(100)
    later = events(tracer) -- events
    check("no events for an unstamped broadcast (zero idle footprint)", later == [])

    :seq_trace.set_system_tracer(false)
  end

  def part3_coexistence do
    IO.puts("Part 3 — seq_trace + :trace session on the same process")
    seq_tracer = collector()
    session_tracer = collector()
    :seq_trace.set_system_tracer(seq_tracer)
    session = :trace.session_create(:spike_a6, session_tracer, [])
    parent = self()

    receiver =
      spawn(fn ->
        receive do
          _ -> :ok
        end
      end)

    stamper =
      spawn(fn ->
        receive do
          :go ->
            :seq_trace.set_token(:label, {:wiretap, 2})
            :seq_trace.set_token(:send, true)
            send(receiver, :both_traced)
            :seq_trace.set_token([])
            send(parent, :done)
        end
      end)

    1 = :trace.process(session, stamper, true, [:send])
    send(stamper, :go)

    receive do
      :done -> :ok
    end

    Process.sleep(100)

    seq_events =
      for {:seq_trace, {:wiretap, 2}, {:send, _s, _f, to, :both_traced}} <- events(seq_tracer), do: to

    session_events =
      for {:trace, pid, :send, :both_traced, to} <- events(session_tracer), do: {pid, to}

    check("seq_trace saw the send", seq_events == [receiver])
    check("trace session saw the same send", {stamper, receiver} in session_events)

    :trace.session_destroy(session)
    :seq_trace.set_system_tracer(false)
    check("session destroyed cleanly", true)
  end
end

IO.puts("Spike A6 — seq_trace under OTP #{:erlang.system_info(:otp_release)}\n")
SpikeA6.part1_singleton()
SpikeA6.part2_fanout()
SpikeA6.part3_coexistence()
