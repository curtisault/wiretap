defmodule Wiretap.SeqTracer do
  @moduledoc """
  Broadcast Trace (3b): the fan-out tree of one stamped broadcast.

  **Injected, not intercepted** (discovery v0.4): a seq token can only be
  stamped by the sending process, so wiretap sends the broadcast itself from a
  dedicated stamper process and collects the delivery tree. Tokens propagate
  through relays, so second-order hops (a subscriber re-broadcasting) appear
  in the tree with causal serials and per-hop timestamps — across every hop.

  This GenServer is the node-wide arbiter for the `seq_trace` system tracer
  (a per-node singleton, spike A6): requests serialize through it, a foreign
  system tracer is detected and refused (§8.3), and the tracer slot is always
  released — footprint is exactly zero when no trace is running.

  Spike P1 finding honored here: exit signals also carry the token and surface
  as sends; they are classified out of the delivery tree.
  """

  use GenServer

  alias Wiretap.Snapshot

  @collect_ms 250
  @preview_opts [limit: 5, printable_limit: 128]

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @typedoc "One delivery hop in the fan-out tree."
  @type hop :: %{
          serial: {non_neg_integer(), non_neg_integer()},
          depth: pos_integer(),
          from: pid(),
          from_label: String.t(),
          to: pid(),
          to_label: String.t(),
          at_us: integer(),
          delta_us: non_neg_integer(),
          message_preview: String.t()
        }

  @doc """
  Sends `message` on `topic` with a seq token and returns the delivery tree.

  Options: `:collect_ms` (how long to keep collecting hops after the
  broadcast, default #{@collect_ms} — raise it when relays are slow).

  Returns `{:ok, %{topic: topic, message_preview: preview, hops: [hop]}}` —
  an empty `hops` list answers "is it even wired?" — or
  `{:error, :foreign_tracer}` when another tool owns the seq_trace system
  tracer. Concurrent requests serialize; each gets its own tree.
  """
  @spec trace_broadcast(atom(), String.t(), term(), keyword()) ::
          {:ok, %{topic: String.t(), message_preview: String.t(), hops: [hop()]}}
          | {:error, :foreign_tracer}
  def trace_broadcast(pubsub, topic, message, opts \\ []) do
    collect_ms = Keyword.get(opts, :collect_ms, @collect_ms)
    GenServer.call(__MODULE__, {:trace, pubsub, topic, message, collect_ms}, collect_ms + 5_000)
  end

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def handle_call({:trace, pubsub, topic, message, collect_ms}, _from, state) do
    reply =
      case :seq_trace.set_system_tracer(self()) do
        false ->
          try do
            run(pubsub, topic, message, collect_ms)
          after
            :seq_trace.set_system_tracer(false)
            flush_seq()
          end

        previous ->
          # someone else owns the singleton — put it back untouched (§8.3)
          :seq_trace.set_system_tracer(previous)
          {:error, :foreign_tracer}
      end

    {:reply, reply, state}
  end

  defp run(pubsub, topic, message, collect_ms) do
    label = {:wiretap, make_ref()}
    arbiter = self()

    stamper =
      spawn(fn ->
        :seq_trace.set_token(:label, label)
        :seq_trace.set_token(:send, true)
        :seq_trace.set_token(:timestamp, true)
        _ = Phoenix.PubSub.broadcast(pubsub, topic, message)
        :seq_trace.set_token([])
        send(arbiter, {:stamped, self()})
      end)

    receive do
      {:stamped, ^stamper} -> :ok
    after
      1_000 -> :ok
    end

    deadline = System.monotonic_time(:millisecond) + collect_ms
    hops = collect(label, deadline, [])

    {:ok,
     %{
       topic: topic,
       message_preview: inspect(message, @preview_opts),
       hops: assemble(hops, stamper)
     }}
  end

  defp collect(label, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:seq_trace, ^label, {:send, serial, from, to, msg}, ts} ->
        collect(label, deadline, [%{serial: serial, from: from, to: to, msg: msg, ts: ts} | acc])
    after
      remaining -> Enum.reverse(acc)
    end
  end

  defp assemble(raw, stamper) do
    hops =
      raw
      # exit signals carry the token too (spike P1) — not deliveries
      |> Enum.reject(&match?({:EXIT, _pid, _reason}, &1.msg))
      |> Enum.sort_by(& &1.serial)

    origin_us =
      case hops do
        [] -> 0
        [first | _rest] -> ts_us(first.ts)
      end

    {entries, _depths} =
      Enum.map_reduce(hops, %{stamper => 0}, fn hop, depths ->
        depth = Map.get(depths, hop.from, 0) + 1

        entry = %{
          serial: hop.serial,
          depth: depth,
          from: hop.from,
          from_label: Snapshot.label(hop.from),
          to: hop.to,
          to_label: Snapshot.label(hop.to),
          at_us: ts_us(hop.ts),
          delta_us: max(ts_us(hop.ts) - origin_us, 0),
          message_preview: inspect(hop.msg, @preview_opts)
        }

        {entry, Map.put_new(depths, hop.to, depth)}
      end)

    entries
  end

  defp ts_us({mega, sec, micro}), do: mega * 1_000_000_000_000 + sec * 1_000_000 + micro

  defp flush_seq do
    receive do
      {:seq_trace, _label, _info} -> flush_seq()
      {:seq_trace, _label, _info, _ts} -> flush_seq()
    after
      0 -> :ok
    end
  end
end
