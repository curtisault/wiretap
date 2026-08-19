defmodule Harness.TelemetryDebug do
  @moduledoc """
  Console tap for telemetry while driving the demo from iex.

      Harness.TelemetryDebug.on()        # wiretap's own events
      Harness.TelemetryDebug.on(:tower)  # + tower traffic (noisy: every 2s per flight)
      Harness.TelemetryDebug.off()

  A dev-harness convenience only: wiretap-the-library never attaches handlers
  on its own (idle = free) — this module is the *host* doing the attaching,
  which is exactly the boundary the safety contract draws.
  """

  require Logger

  @handler_id "harness-telemetry-debug"

  @wiretap_events [
    [:wiretap, :session, :start],
    [:wiretap, :session, :stop],
    [:wiretap, :budget, :exhausted],
    [:wiretap, :collector, :dropped],
    [:wiretap, :registry, :incompatible]
  ]

  @tower_events [
    [:harness, :tower, :entered],
    [:harness, :tower, :landed],
    [:harness, :tower, :transmission]
  ]

  @doc """
  Attaches a pretty-printing Logger handler. `:wiretap` (default) covers
  wiretap's own events — session lifecycle, budget exhaustion, drops,
  registry incompatibility. `:tower` / `:all` adds the harness tower events.
  Calling `on/1` again just switches scope.
  """
  def on(scope \\ :wiretap)
  def on(:wiretap), do: attach(@wiretap_events)
  def on(:tower), do: attach(@wiretap_events ++ @tower_events)
  def on(:all), do: on(:tower)

  @doc "Detaches the console tap."
  def off do
    :telemetry.detach(@handler_id)
    :ok
  end

  defp attach(events) do
    :telemetry.detach(@handler_id)
    :ok = :telemetry.attach_many(@handler_id, events, &__MODULE__.handle_event/4, nil)
    {:ok, Enum.map(events, &Enum.join(&1, "."))}
  end

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    Logger.info(fn ->
      [
        "◉ ",
        Enum.join(event, "."),
        "  measurements=",
        inspect(measurements, limit: 10),
        "  metadata=",
        inspect(metadata, limit: 8, printable_limit: 256)
      ]
    end)
  end
end
