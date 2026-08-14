defmodule Harness.Broadcaster do
  @moduledoc """
  Timer-driven PubSub traffic so Wiretap panels have something to show.

  Every 2s broadcasts an `{:announcement, n}` to `"airwaves:announcements"` and a
  `{:now_playing, station, track}` to one of the `"station:jazz"` / `"station:news"` /
  `"station:sports"` topics.
  """

  use GenServer

  @interval :timer.seconds(2)
  @playlists %{
    "jazz" => ["Blue in Green", "Take Five", "So What"],
    "news" => ["Top of the Hour", "Traffic & Weather", "Markets Update"],
    "sports" => ["Match Recap", "Halftime Show", "Transfer Rumors"]
  }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule()
    {:ok, 0}
  end

  @impl true
  def handle_info(:broadcast, n) do
    {station, playlist} = Enum.random(@playlists)
    Phoenix.PubSub.broadcast(Harness.PubSub, "airwaves:announcements", {:announcement, n})

    Phoenix.PubSub.broadcast(
      Harness.PubSub,
      "station:" <> station,
      {:now_playing, station, Enum.random(playlist)}
    )

    schedule()
    {:noreply, n + 1}
  end

  defp schedule, do: Process.send_after(self(), :broadcast, @interval)
end
