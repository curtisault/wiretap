defmodule Wiretap.TestHelpersTest do
  use ExUnit.Case, async: true

  import Wiretap.Test

  defp start_pubsub do
    name = :"pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: name})
    name
  end

  defp subscribe(pubsub, topic) do
    parent = self()

    pid =
      spawn(fn ->
        :ok = Phoenix.PubSub.subscribe(pubsub, topic)
        send(parent, {:ready, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:ready, ^pid}
    pid
  end

  test "assert_subscribed passes for a subscriber and defaults to self()" do
    pubsub = start_pubsub()
    listener = subscribe(pubsub, "station:jazz")
    assert assert_subscribed(pubsub, "station:jazz", listener)

    :ok = Phoenix.PubSub.subscribe(pubsub, "station:news")
    assert assert_subscribed(pubsub, "station:news")
  end

  test "assert_subscribed flunks with a roll call of the topic and the pid" do
    pubsub = start_pubsub()
    other = subscribe(pubsub, "station:jazz")
    :ok = Phoenix.PubSub.subscribe(pubsub, "station:news")

    error =
      assert_raise ExUnit.AssertionError, fn ->
        assert_subscribed(pubsub, "station:jazz")
      end

    assert error.message =~ "to be subscribed to \"station:jazz\""
    assert error.message =~ inspect(other)
    assert error.message =~ "station:news"
  end

  test "refute_subscribed passes immediately after a synchronous unsubscribe" do
    pubsub = start_pubsub()
    :ok = Phoenix.PubSub.subscribe(pubsub, "station:jazz")
    :ok = Phoenix.PubSub.unsubscribe(pubsub, "station:jazz")

    assert refute_subscribed(pubsub, "station:jazz")
  end

  test "refute_subscribed flunks for a live subscription" do
    pubsub = start_pubsub()
    listener = subscribe(pubsub, "station:jazz")

    error =
      assert_raise ExUnit.AssertionError, fn ->
        refute_subscribed(pubsub, "station:jazz", listener)
      end

    assert error.message =~ "NOT to be subscribed"
  end

  test "timeout option rides out asynchronous death cleanup" do
    pubsub = start_pubsub()
    listener = subscribe(pubsub, "station:jazz")

    ref = Process.monitor(listener)
    send(listener, :stop)
    assert_receive {:DOWN, ^ref, :process, ^listener, _}

    assert refute_subscribed(pubsub, "station:jazz", listener, timeout: 500)
    assert assert_no_subscribers(pubsub, "station:jazz", timeout: 500)
  end

  test "assert_no_subscribers flunks with labeled subscribers" do
    pubsub = start_pubsub()
    listener = subscribe(pubsub, "station:jazz")

    error =
      assert_raise ExUnit.AssertionError, fn ->
        assert_no_subscribers(pubsub, "station:jazz")
      end

    assert error.message =~ "Expected no subscribers"
    assert error.message =~ inspect(listener)
  end
end
