defmodule HarnessWeb.DemoLive do
  @moduledoc """
  Demo LiveView exercising the subscription patterns Wiretap exists to observe:

  * subscribes to `"airwaves:announcements"` on mount (steady-state subscriber)
  * "tune to <station>" subscribes to `"station:<name>"` — the modal-open pattern
  * "tune out" unsubscribes — the well-behaved close path
  * "walk away (leaky)" leaves WITHOUT unsubscribing — the subscription-leak bug class
  """

  use HarnessWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Phoenix.PubSub.subscribe(Harness.PubSub, "airwaves:announcements")
    end

    {:ok, assign(socket, tuned: nil, announcement: nil, now_playing: nil, leaked: 0)}
  end

  @impl true
  def handle_event("tune_in", %{"station" => station}, socket) do
    :ok = Phoenix.PubSub.subscribe(Harness.PubSub, "station:" <> station)
    {:noreply, assign(socket, tuned: station)}
  end

  def handle_event("tune_out", _params, socket) do
    if station = socket.assigns.tuned do
      :ok = Phoenix.PubSub.unsubscribe(Harness.PubSub, "station:" <> station)
    end

    {:noreply, assign(socket, tuned: nil)}
  end

  def handle_event("walk_away", _params, socket) do
    {:noreply, assign(socket, tuned: nil, leaked: socket.assigns.leaked + 1)}
  end

  @impl true
  def handle_info({:announcement, n}, socket), do: {:noreply, assign(socket, announcement: n)}

  def handle_info({:now_playing, station, track}, socket) do
    {:noreply, assign(socket, now_playing: {station, track})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-xl space-y-6 py-10">
        <h1 class="text-2xl font-bold">Wiretap demo harness</h1>

        <p>announcement: <span class="font-mono">{inspect(@announcement)}</span></p>
        <p>now playing: <span class="font-mono">{inspect(@now_playing)}</span></p>
        <p>leaked subscriptions this process: <span class="font-mono">{@leaked}</span></p>

        <div class="flex gap-2">
          <button
            :for={station <- ~w(jazz news sports)}
            class="btn"
            phx-click="tune_in"
            phx-value-station={station}
          >
            tune to {station}
          </button>
        </div>

        <div :if={@tuned} class="rounded border p-4 space-y-2">
          <p>tuned to {@tuned} (subscribed to station:{@tuned})</p>
          <div class="flex gap-2">
            <button class="btn" phx-click="tune_out">tune out</button>
            <button class="btn btn-warning" phx-click="walk_away">walk away (leaky)</button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
