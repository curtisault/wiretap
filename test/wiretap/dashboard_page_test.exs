defmodule Wiretap.DashboardPageTest do
  use ExUnit.Case, async: true

  alias Wiretap.DashboardPage
  alias Wiretap.Snapshot

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

  defp params(overrides \\ %{}) do
    Map.merge(%{search: nil, sort_by: :subscribers, sort_dir: :desc, limit: 50}, overrides)
  end

  test "roll_call/1 returns counts and labeled pids per topic" do
    pubsub = start_pubsub()
    subscribe(pubsub, "station:jazz")
    subscribe(pubsub, "station:jazz")
    subscribe(pubsub, "station:news")

    rows = Snapshot.roll_call(pubsub)

    assert %{topic: "station:jazz", subscribers: 2, pids: [label | _]} =
             Enum.find(rows, &(&1.topic == "station:jazz"))

    assert is_binary(label)
    assert %{subscribers: 1} = Enum.find(rows, &(&1.topic == "station:news"))
  end

  test "init requires a pubsub and mount assigns it" do
    assert {:ok, %{pubsub: :some_pubsub}} = DashboardPage.init(pubsub: :some_pubsub)
    assert_raise ArgumentError, ~r/needs a :pubsub/, fn -> DashboardPage.init([]) end
  end

  test "fetch_rows sorts by subscriber count descending by default" do
    pubsub = start_pubsub()
    subscribe(pubsub, "station:jazz")
    subscribe(pubsub, "station:jazz")
    subscribe(pubsub, "station:news")

    {shown, total} = DashboardPage.fetch_rows(params(), node(), pubsub)

    assert total == 2
    assert Enum.map(shown, & &1.topic) == ["station:jazz", "station:news"]
  end

  test "fetch_rows filters by search and honors the limit" do
    pubsub = start_pubsub()
    subscribe(pubsub, "station:jazz")
    subscribe(pubsub, "station:news")
    subscribe(pubsub, "airwaves:announcements")

    {shown, total} = DashboardPage.fetch_rows(params(%{search: "station:"}), node(), pubsub)
    assert total == 2
    assert Enum.all?(shown, &String.starts_with?(&1.topic, "station:"))

    {limited, total} = DashboardPage.fetch_rows(params(%{limit: 1}), node(), pubsub)
    assert total == 3
    assert length(limited) == 1
  end
end
