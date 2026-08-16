defmodule WiretapTest do
  use ExUnit.Case, async: true

  test "public API delegates to Snapshot" do
    pubsub = :"pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    assert Wiretap.snapshot(pubsub) == %{}
    assert Wiretap.topics(pubsub) == []
    assert Wiretap.subscribers(pubsub, "station:jazz") == []
  end
end
