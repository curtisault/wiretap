defmodule Wiretap.Test do
  @moduledoc """
  ExUnit assertion helpers for PubSub subscription hygiene.

  These replace hand-rolled `Registry.keys/2` inspection in host test suites:

      import Wiretap.Test

      test "tuning in subscribes exactly one station", %{pubsub: pubsub} do
        view |> element("button", "tune to jazz") |> render_click()
        assert_subscribed(pubsub, "station:jazz", view.pid)

        view |> element("button", "tune out") |> render_click()
        refute_subscribed(pubsub, "station:jazz", view.pid)
      end

  All helpers are point-in-time reads by default. Registry cleanup after a
  subscriber *dies* is asynchronous, so assertions that race a death (or any
  async subscribe path) can pass `timeout: ms` to retry every 10ms until the
  condition holds or the timeout elapses.

  Failure messages include the topic's current subscribers and the pid's
  current topics, labeled via `Wiretap.Snapshot.label/1`, so a failing
  hygiene test reads like a Roll Call panel.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  alias Wiretap.Snapshot

  @poll_ms 10

  @doc """
  Asserts `pid` is currently subscribed to `topic` on `pubsub`.

  Defaults to `self()`. Accepts `timeout: ms` to retry until true.
  """
  @spec assert_subscribed(Snapshot.pubsub(), Snapshot.topic(), pid(), keyword()) :: true
  def assert_subscribed(pubsub, topic, pid \\ self(), opts \\ []) do
    wait_until(opts, fn -> pid in Snapshot.subscribers(pubsub, topic) end) ||
      flunk("""
      Expected #{describe(pid)} to be subscribed to #{inspect(topic)}.

      #{roll_call(pubsub, topic, pid)}\
      """)
  end

  @doc """
  Asserts `pid` is NOT subscribed to `topic` on `pubsub`.

  Defaults to `self()`. Accepts `timeout: ms` — useful after a subscriber
  dies, since the registry cleans up asynchronously.
  """
  @spec refute_subscribed(Snapshot.pubsub(), Snapshot.topic(), pid(), keyword()) :: true
  def refute_subscribed(pubsub, topic, pid \\ self(), opts \\ []) do
    wait_until(opts, fn -> pid not in Snapshot.subscribers(pubsub, topic) end) ||
      flunk("""
      Expected #{describe(pid)} NOT to be subscribed to #{inspect(topic)}, but it is.

      #{roll_call(pubsub, topic, pid)}\
      """)
  end

  @doc """
  Asserts `topic` has no subscribers at all — the "is it even wired?"
  inverse: proves a teardown path really unwired everything.

  Accepts `timeout: ms`.
  """
  @spec assert_no_subscribers(Snapshot.pubsub(), Snapshot.topic(), keyword()) :: true
  def assert_no_subscribers(pubsub, topic, opts \\ []) do
    wait_until(opts, fn -> Snapshot.subscribers(pubsub, topic) == [] end) ||
      flunk("""
      Expected no subscribers on #{inspect(topic)}, but found:

      #{subscriber_lines(pubsub, topic)}\
      """)
  end

  defp wait_until(opts, condition) do
    timeout = Keyword.get(opts, :timeout, 0)
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(condition, deadline)
  end

  defp poll(condition, deadline) do
    cond do
      condition.() ->
        true

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(@poll_ms)
        poll(condition, deadline)

      true ->
        false
    end
  end

  defp describe(pid), do: "#{inspect(pid)} (#{Snapshot.label(pid)})"

  defp roll_call(pubsub, topic, pid) do
    pid_topics =
      pubsub
      |> Snapshot.take()
      |> Enum.filter(fn {_topic, pids} -> pid in pids end)
      |> Enum.map(fn {topic, _pids} -> topic end)
      |> Enum.sort()

    """
    Subscribers of #{inspect(topic)}:
    #{subscriber_lines(pubsub, topic)}
    Topics #{inspect(pid)} is subscribed to: #{inspect(pid_topics)}
    """
  end

  defp subscriber_lines(pubsub, topic) do
    case Snapshot.subscribers(pubsub, topic) do
      [] -> "  (none)\n"
      pids -> Enum.map_join(pids, "\n", &"  #{describe(&1)}") <> "\n"
    end
  end
end
