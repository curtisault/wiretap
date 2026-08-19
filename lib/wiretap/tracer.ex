defmodule Wiretap.Tracer do
  @moduledoc """
  Layer 2: exact subscribe/unsubscribe events via OTP trace sessions
  (never legacy global tracing — §8.3).

  One Tracer per trace-enabled session, **replacing** the Snapshotter: it
  seeds a silent baseline from one snapshot at start, then relies on trace
  events — no polling, no polling gap. The process is both the owner of its
  `:trace` session (the VM destroys the session if this process dies —
  crash-safe teardown) and its passive receiver
  (`message_queue_data: :off_heap`, discovery A5).

  It also owns the monitors: every subscribed pid (baseline included) is
  monitored the moment it is known, so a subscriber that joins and dies within
  milliseconds still yields `left_by_death` — a guarantee polling cannot make.

  Arming rules from spike T1:

  * **Both arities, `:global` only.** `Phoenix.PubSub.subscribe(pubsub, topic)`
    is the arity-2 default-args wrapper, reaching `/3` via a *local* call that
    global tracing never sees. External-only tracing on both arities also keeps
    `{:caller}` pointing at the real caller and cannot double-count.
  * Topic prefixes filter **in the VM** via `binary_part` match-spec guards —
    uninteresting calls generate no trace messages at all.
  * Direct `Registry.register/unregister` users are **not** traced in v0.3:
    tail-call optimization erases the caller frame (`unsubscribe/2` is a tail
    delegate), making dedup against the PubSub events unsound. Recorded as a
    discovery deviation; revisit with v0.4.

  Note `{:caller}` reports the nearest *non-tail* caller: a wrapper that tail-
  delegates to `Phoenix.PubSub.subscribe` attributes to the wrapper's caller —
  arguably the truer answer.

  Overload: above a queue high-watermark the receiver consumes-and-counts
  instead of forwarding, then emits `[:wiretap, :collector, :dropped]` once
  the queue drains below the low-watermark. `:DOWN` messages are always
  processed — death truth survives drop mode.
  """

  use GenServer

  alias Wiretap.Collector
  alias Wiretap.Snapshot

  @high_watermark 5_000
  @low_watermark 500
  @preview_opts [limit: 5, printable_limit: 128]

  @doc "Whether OTP trace sessions are available on this node (OTP 27+)."
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(:trace) and function_exported?(:trace, :session_create, 3)
  end

  @doc false
  def start_link(session) do
    GenServer.start_link(__MODULE__, session, name: via(session.name))
  end

  defp via(session_name), do: {:via, Registry, {Wiretap.Registry, {session_name, :tracer}}}

  @impl true
  def init(session) do
    Process.flag(:trap_exit, true)
    Process.flag(:message_queue_data, :off_heap)

    # The session NAME is a debugging label and need not be unique — the
    # returned handle identifies the session. A constant atom avoids minting
    # an atom per capture session (sobelow's DOS.BinToAtom, and a real leak).
    trace_session = :trace.session_create(:wiretap, self(), [])
    arm(trace_session, session)

    state = %{
      session: session,
      trace_session: trace_session,
      topics: %{},
      monitors: %{},
      dropping?: false,
      dropped: 0
    }

    {:ok, if(session.trace, do: seed_baseline(state), else: state)}
  end

  @impl true
  def terminate(_reason, state) do
    :trace.session_destroy(state.trace_session)
    :ok
  end

  # Pre-existing subscribers never make a traced call; one snapshot at start
  # (silent — no events) seeds the topic map so their deaths are still caught.
  defp seed_baseline(state) do
    %{prefixes: prefixes} = state.session.trace

    state.session.pubsub
    |> Snapshot.take()
    |> Enum.filter(fn {topic, _pids} -> prefixes == [] or prefix_match?(topic, prefixes) end)
    |> Enum.reduce(state, fn {topic, pids}, acc ->
      Enum.reduce(pids, acc, &track(&2, &1, topic))
    end)
  end

  defp prefix_match?(topic, prefixes) do
    Enum.any?(prefixes, &String.starts_with?(topic, &1))
  end

  defp arm(trace_session, session) do
    if session.trace, do: arm_calls(trace_session, session)

    # Layer 3a: per-pid :receive tracing on explicitly selected pids only —
    # never groups, never :all (§3a).
    for pid <- session.tap do
      :trace.process(trace_session, pid, true, [:receive])
    end

    :ok
  end

  defp arm_calls(trace_session, session) do
    %{prefixes: prefixes, mfas: mfas} = session.trace
    pubsub = session.pubsub

    patterns = [
      {{Phoenix.PubSub, :subscribe, 2}, [:"$2", :"$1"]},
      {{Phoenix.PubSub, :subscribe, 3}, [:"$2", :"$1", :_]},
      {{Phoenix.PubSub, :unsubscribe, 2}, [:"$2", :"$1"]}
    ]

    for {mfa, head} <- patterns do
      :trace.function(trace_session, mfa, topic_match_spec(head, pubsub, prefixes), [:global])
    end

    for {m, f, a} <- mfas do
      :trace.function(trace_session, {m, f, a}, [{:_, [], [{:message, {:caller}}]}], [:global])
    end

    :trace.process(trace_session, :all, true, [:call])
  end

  # $2 = the pubsub argument, $1 = the topic. The prefix filter runs inside
  # the VM: a non-matching call produces no trace message at all.
  defp topic_match_spec(head, pubsub, prefixes) do
    pubsub_guard = {:"=:=", :"$2", pubsub}

    guard =
      case prefixes do
        [] ->
          pubsub_guard

        prefixes ->
          {:andalso, pubsub_guard, {:andalso, {:is_binary, :"$1"}, prefix_guard(prefixes)}}
      end

    [{head, [guard], [{:message, {{:"$1", {:caller}}}}]}]
  end

  defp prefix_guard([prefix]), do: one_prefix(prefix)
  defp prefix_guard([prefix | rest]), do: {:orelse, one_prefix(prefix), prefix_guard(rest)}

  defp one_prefix(prefix) do
    {:==, {:binary_part, :"$1", 0, byte_size(prefix)}, prefix}
  end

  @impl true
  def handle_info({:trace, pid, :receive, message}, state) do
    state = drop_control(state)

    if state.dropping? do
      {:noreply, %{state | dropped: state.dropped + 1}}
    else
      push(state.session, %{
        kind: :message,
        source: :receive_trace,
        pid: pid,
        payload_preview: message_preview(message, state.session.payloads)
      })

      {:noreply, state}
    end
  end

  def handle_info({:trace, pid, :call, mfa_args}, state) do
    handle_trace(pid, mfa_args, nil, state)
  end

  def handle_info({:trace, pid, :call, mfa_args, extra}, state) do
    handle_trace(pid, mfa_args, extra, state)
  end

  # Death truth is exempt from drop mode: left_by_death per subscribed topic.
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    for topic <- Map.get(state.topics, pid, MapSet.new()) do
      push(state.session, %{
        kind: :left_by_death,
        source: :monitor,
        topic: topic,
        pid: pid,
        meta: %{reason: reason}
      })
    end

    {:noreply, forget(state, pid)}
  end

  def handle_info({:EXIT, _from, reason}, state), do: {:stop, reason, state}
  def handle_info(_other, state), do: {:noreply, state}

  defp handle_trace(pid, mfa_args, extra, state) do
    state = drop_control(state)

    if state.dropping? do
      {:noreply, %{state | dropped: state.dropped + 1}}
    else
      {:noreply, push_event(pid, mfa_args, extra, state)}
    end
  end

  defp push_event(pid, {Phoenix.PubSub, :subscribe, _args}, {topic, caller}, state) do
    push(state.session, %{
      kind: :joined,
      source: :trace,
      topic: topic,
      pid: pid,
      meta: %{caller: caller}
    })

    track(state, pid, topic)
  end

  defp push_event(pid, {Phoenix.PubSub, :unsubscribe, _args}, {topic, caller}, state) do
    push(state.session, %{
      kind: :left,
      source: :trace,
      topic: topic,
      pid: pid,
      meta: %{caller: caller}
    })

    untrack(state, pid, topic)
  end

  # User-added wrapper MFA: extra is the caller alone.
  defp push_event(pid, {m, f, args}, caller, state) do
    push(state.session, %{
      kind: :call,
      source: :trace,
      pid: pid,
      payload_preview: inspect(args, @preview_opts),
      meta: %{mfa: {m, f, length(args)}, caller: caller}
    })

    state
  end

  defp push(session, attrs), do: Collector.push(session.name, attrs)

  # B7 payload knob: previews only, sized by the session's :payloads setting.
  defp message_preview(_message, :off), do: nil

  defp message_preview(message, :unlimited) do
    inspect(message, limit: :infinity, printable_limit: :infinity)
  end

  defp message_preview(message, bytes) when is_integer(bytes) do
    preview = inspect(message, limit: 50, printable_limit: bytes)

    if byte_size(preview) > bytes do
      String.slice(preview, 0, bytes) <> "…"
    else
      preview
    end
  end

  defp track(state, pid, topic) do
    topics = Map.update(state.topics, pid, MapSet.new([topic]), &MapSet.put(&1, topic))

    monitors =
      Map.put_new_lazy(state.monitors, pid, fn -> Process.monitor(pid) end)

    %{state | topics: topics, monitors: monitors}
  end

  defp untrack(state, pid, topic) do
    remaining = state.topics |> Map.get(pid, MapSet.new()) |> MapSet.delete(topic)

    if MapSet.size(remaining) == 0 do
      case state.monitors do
        %{^pid => ref} -> Process.demonitor(ref, [:flush])
        _ -> :ok
      end

      forget(state, pid)
    else
      %{state | topics: Map.put(state.topics, pid, remaining)}
    end
  end

  defp forget(state, pid) do
    %{state | topics: Map.delete(state.topics, pid), monitors: Map.delete(state.monitors, pid)}
  end

  defp drop_control(state) do
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)

    cond do
      state.dropping? and len < @low_watermark ->
        :telemetry.execute([:wiretap, :collector, :dropped], %{count: state.dropped}, %{
          session: state.session.name
        })

        %{state | dropping?: false, dropped: 0}

      not state.dropping? and len > @high_watermark ->
        %{state | dropping?: true, dropped: 0}

      true ->
        state
    end
  end
end
