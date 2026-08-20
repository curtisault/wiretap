defmodule Harness.Transmit do
  @moduledoc """
  Manual radio for the demo: send your own broadcasts on `Harness.PubSub`
  from iex and watch them arrive through wiretap — in a tapped pid's
  Timeline, a Broadcast Trace tree, or an Inspector message feed.

      Harness.Transmit.broadcast("station:alpha", {:msg, "hello"})
      Harness.Transmit.to_flight("WT-101", {:atc, :cleared_to_land})
      Harness.Transmit.atc({:advisory, :runway_change})
      Harness.Transmit.burst("atc:events", 500)   # trip a max_rate budget

  The demo's organic traffic comes from `Harness.Tower`; this module is the
  human keying the mic. It is host-side by design — wiretap itself never
  sends to host topics (read-only contract); the harness doing it is normal
  app behavior.
  """

  @pubsub Harness.PubSub

  @doc "Broadcasts `message` on any topic."
  def broadcast(topic, message) when is_binary(topic) do
    Phoenix.PubSub.broadcast(@pubsub, topic, message)
  end

  @doc ~S(Transmits to one flight's frequency: `"flight:<callsign>"`.)
  def to_flight(callsign, message) when is_binary(callsign) do
    broadcast("flight:" <> callsign, message)
  end

  @doc ~S(Puts a message on the shared `"atc:events"` frequency.)
  def atc(message), do: broadcast("atc:events", message)

  @doc """
  Sends `count` numbered `{:burst, n, count}` messages on `topic`, as fast
  as `:interval_ms` allows (default 0 — flat out). Runs in a spawned process
  so iex stays free; returns the sender's pid.

  Built for tripping budgets on purpose: watch a session hit `max_rate`
  (250/s default) or `max_events`, then see `[:wiretap, :budget, :exhausted]`
  fire (`Harness.TelemetryDebug.on()` prints it).
  """
  def burst(topic, count, opts \\ []) when is_integer(count) and count > 0 do
    interval = Keyword.get(opts, :interval_ms, 0)

    spawn(fn ->
      for n <- 1..count do
        broadcast(topic, {:burst, n, count})
        if interval > 0, do: Process.sleep(interval)
      end
    end)
  end
end
