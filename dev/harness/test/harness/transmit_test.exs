defmodule Harness.TransmitTest do
  use ExUnit.Case, async: true

  alias Harness.Transmit

  test "broadcast/2, to_flight/2, and atc/1 deliver on their topics" do
    :ok = Phoenix.PubSub.subscribe(Harness.PubSub, "station:alpha")
    :ok = Phoenix.PubSub.subscribe(Harness.PubSub, "flight:WT-900")
    :ok = Phoenix.PubSub.subscribe(Harness.PubSub, "atc:events")

    :ok = Transmit.broadcast("station:alpha", {:msg, "hello"})
    assert_receive {:msg, "hello"}

    :ok = Transmit.to_flight("WT-900", {:atc, :cleared_to_land})
    assert_receive {:atc, :cleared_to_land}

    :ok = Transmit.atc({:advisory, :runway_change})
    assert_receive {:advisory, :runway_change}
  end

  test "burst/3 sends every numbered message without blocking the caller" do
    :ok = Phoenix.PubSub.subscribe(Harness.PubSub, "station:burst-test")

    pid = Transmit.burst("station:burst-test", 5)
    assert is_pid(pid)

    for n <- 1..5 do
      assert_receive {:burst, ^n, 5}
    end

    refute_receive {:burst, _, _}, 50
  end
end
