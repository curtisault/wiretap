defmodule Harness.TelemetryDebugTest do
  # attaches/detaches a named global telemetry handler — keep synchronous
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Harness.TelemetryDebug

  setup do
    # the console tap logs at :info; the test env's primary level is :warning
    level = Logger.level()
    Logger.configure(level: :info)

    on_exit(fn ->
      Logger.configure(level: level)
      TelemetryDebug.off()
    end)
  end

  test "on/0 prints wiretap's own events; off/0 goes silent" do
    assert {:ok, events} = TelemetryDebug.on()
    assert "wiretap.budget.exhausted" in events

    log =
      capture_log([level: :info], fn ->
        :telemetry.execute([:wiretap, :budget, :exhausted], %{limit: 1000}, %{bound: :max_events})
      end)

    assert log =~ "wiretap.budget.exhausted"
    assert log =~ "limit: 1000"

    TelemetryDebug.off()

    log =
      capture_log([level: :info], fn ->
        :telemetry.execute([:wiretap, :budget, :exhausted], %{limit: 1000}, %{bound: :max_events})
      end)

    refute log =~ "wiretap.budget.exhausted"
  end

  test "on(:tower) adds the tower events; repeated on/1 switches scope" do
    {:ok, events} = TelemetryDebug.on(:tower)
    assert "harness.tower.transmission" in events

    log =
      capture_log([level: :info], fn ->
        :telemetry.execute([:harness, :tower, :landed], %{}, %{callsign: "WT-101"})
      end)

    assert log =~ "harness.tower.landed"
    assert log =~ "WT-101"

    # narrowing back to :wiretap drops the tower scope
    {:ok, _} = TelemetryDebug.on(:wiretap)

    log =
      capture_log([level: :info], fn ->
        :telemetry.execute([:harness, :tower, :landed], %{}, %{callsign: "WT-101"})
      end)

    refute log =~ "harness.tower.landed"
  end

  test "the running tower emits transmission telemetry the bridge can attach to" do
    parent = self()

    :telemetry.attach(
      "tower-test-#{inspect(self())}",
      [:harness, :tower, :transmission],
      fn _event, measurements, metadata, _config ->
        send(parent, {:transmission, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("tower-test-#{inspect(self())}") end)

    # the tower ticks every 2s with at least 2 active flights
    assert_receive {:transmission, measurements, metadata}, 3_000
    assert is_integer(measurements.alt)
    assert metadata.topic == "flight:" <> metadata.callsign
  end
end
