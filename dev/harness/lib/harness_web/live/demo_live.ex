defmodule HarnessWeb.DemoLive do
  @moduledoc """
  Demo LiveView exercising the subscription patterns Wiretap exists to observe.

  You are an air traffic controller: track as many flights as you like — the
  realistic PubSub pattern, where one process holds several subscriptions on
  topics that come and go (the roster fluctuates between 2 and 25 flights).

  * subscribes to `"atc:events"` on mount (steady-state subscriber)
  * clicking a flight in the Airspace column toggles a subscription to
    `"flight:<callsign>"`
  * "hand off all" unsubscribes everything — the well-behaved close path
  * "walk off shift (leaky)" abandons the scope WITHOUT unsubscribing — the
    subscription-leak bug class, one leak per tracked flight. Leaked flights
    keep transmitting: their reports land in the feed flagged as leaked.
  * clicking a received transmission opens a modal with the full report
    metadata (aircraft, route, squawk, speeds, delivery provenance)

  The "registry truth" panel renders what this LiveView pid is actually
  subscribed to according to `Wiretap.snapshot/1`; the "Wiretap sessions"
  card starts/stops real capture sessions (`Wiretap.watch/2`) with live
  status and captured-event counts.
  """

  use HarnessWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    roster =
      if connected?(socket) do
        :ok = Phoenix.PubSub.subscribe(Harness.PubSub, "atc:events")
        Harness.Tower.active_flights()
      else
        []
      end

    socket =
      socket
      |> assign(
        roster: roster,
        tracking: MapSet.new(),
        last_event: nil,
        received: [],
        leaked: 0,
        selected: nil,
        arm_trace?: true
      )
      |> refresh_registry_truth()

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle", %{"callsign" => callsign}, socket) do
    tracking = socket.assigns.tracking

    tracking =
      if MapSet.member?(tracking, callsign) do
        :ok = Phoenix.PubSub.unsubscribe(Harness.PubSub, "flight:" <> callsign)
        MapSet.delete(tracking, callsign)
      else
        :ok = Phoenix.PubSub.subscribe(Harness.PubSub, "flight:" <> callsign)
        MapSet.put(tracking, callsign)
      end

    {:noreply, socket |> assign(tracking: tracking) |> refresh_registry_truth()}
  end

  def handle_event("hand_off_all", _params, socket) do
    for callsign <- socket.assigns.tracking do
      :ok = Phoenix.PubSub.unsubscribe(Harness.PubSub, "flight:" <> callsign)
    end

    {:noreply, socket |> assign(tracking: MapSet.new()) |> refresh_registry_truth()}
  end

  def handle_event("walk_off_shift", _params, socket) do
    leaked = socket.assigns.leaked + MapSet.size(socket.assigns.tracking)

    {:noreply,
     socket
     |> assign(tracking: MapSet.new(), leaked: leaked)
     |> refresh_registry_truth()}
  end

  def handle_event("arm_change", params, socket) do
    {:noreply, assign(socket, arm_trace?: params["trace"] == "on")}
  end

  def handle_event("start_session", _params, socket) do
    opts =
      if socket.assigns.arm_trace?,
        do: [trace: true],
        else: [interval_ms: 500]

    {:ok, _name} = Wiretap.watch(Harness.PubSub, opts)
    {:noreply, refresh_registry_truth(socket)}
  end

  def handle_event("stop_session", %{"session" => name}, socket) do
    _ = Wiretap.stop(name)
    {:noreply, refresh_registry_truth(socket)}
  end

  def handle_event("inspect", %{"id" => id}, socket) do
    id = String.to_integer(id)
    {:noreply, assign(socket, selected: Enum.find(socket.assigns.received, &(&1.id == id)))}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, selected: nil)}
  end

  @impl true
  def handle_info({:roster, callsigns}, socket) do
    {:noreply, socket |> assign(roster: callsigns) |> refresh_registry_truth()}
  end

  def handle_info({:atc, event, callsign}, socket) do
    {:noreply, assign(socket, last_event: "#{callsign} #{event}")}
  end

  def handle_info({:position, callsign, payload}, socket) do
    entry =
      Map.merge(payload, %{
        id: System.unique_integer([:positive, :monotonic]),
        callsign: callsign,
        received_at: Time.truncate(Time.utc_now(), :second),
        leaked?: not MapSet.member?(socket.assigns.tracking, callsign)
      })

    {:noreply, assign(socket, received: Enum.take([entry | socket.assigns.received], 50))}
  end

  # Shared frequencies carry messages we didn't ask for — wiretap's Broadcast
  # Trace test messages, Harness.Transmit traffic, future tower message types.
  # A subscriber must never crash on static.
  def handle_info(_unknown, socket), do: {:noreply, socket}

  defp refresh_registry_truth(socket) do
    topics =
      if connected?(socket) do
        me = self()

        Harness.PubSub
        |> Wiretap.snapshot()
        |> Enum.filter(fn {_topic, pids} -> me in pids end)
        |> Enum.map(fn {topic, _pids} -> topic end)
        |> Enum.sort()
      else
        []
      end

    sessions =
      for session <- Enum.take(Wiretap.sessions(), 5) do
        %{
          name: session.name,
          status: session.status,
          traced?: session.trace != false,
          events: length(Wiretap.events(session.name))
        }
      end

    assign(socket, my_subscriptions: topics, sessions: sessions)
  end

  defp badge_class(:running), do: "badge-success"
  defp badge_class(:stopped), do: "badge-ghost"
  defp badge_class(:expired), do: "badge-warning"
  defp badge_class(:crashed), do: "badge-error"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-4">
        <div class="flex flex-wrap items-baseline gap-x-6 gap-y-1">
          <h1 class="text-2xl font-bold">ATC console</h1>
          <p class="text-sm opacity-70">
            you are the controller — click flights to track them; they enter and land on their own
          </p>
        </div>

        <div class="flex flex-wrap gap-x-8 text-sm">
          <p>last tower event: <span class="font-mono">{@last_event || "(none yet)"}</span></p>
          <p>subscriptions leaked so far: <span class="font-mono">{@leaked}</span></p>
        </div>

        <div class="grid gap-4 lg:grid-cols-[14rem_minmax(0,1fr)_20rem] lg:h-[calc(100vh-13rem)]">
          <div class="rounded border p-3 space-y-2 lg:overflow-y-auto">
            <h2 class="font-semibold">Airspace ({length(@roster)})</h2>
            <ul class="space-y-1">
              <li
                :for={callsign <- @roster}
                class={[
                  "rounded px-3 py-2 cursor-pointer select-none font-mono text-sm",
                  if(MapSet.member?(@tracking, callsign),
                    do: "bg-primary text-primary-content",
                    else: "hover:bg-base-200"
                  )
                ]}
                phx-click="toggle"
                phx-value-callsign={callsign}
              >
                {callsign}
                <span :if={MapSet.member?(@tracking, callsign)} class="text-xs opacity-80">
                  · tracking
                </span>
              </li>
              <li :if={@roster == []} class="opacity-60 text-sm">(empty airspace)</li>
            </ul>
          </div>

          <div class="space-y-4 lg:overflow-y-auto">
            <div :if={MapSet.size(@tracking) > 0} class="rounded border p-4 space-y-2">
              <h2 class="font-semibold">Your scope ({MapSet.size(@tracking)} flight(s))</h2>
              <ul class="font-mono text-sm space-y-1">
                <li :for={callsign <- Enum.sort(@tracking)}>
                  {callsign}
                  <span :if={callsign not in @roster} class="badge badge-ghost">
                    landed — still subscribed
                  </span>
                </li>
              </ul>
              <div class="flex gap-2">
                <button class="btn" phx-click="hand_off_all">hand off all</button>
                <button class="btn btn-warning" phx-click="walk_off_shift">
                  walk off shift (leaky)
                </button>
              </div>
            </div>

            <div class="rounded border p-4 space-y-2">
              <h2 class="font-semibold">Wiretap sessions</h2>
              <p class="text-sm opacity-70">
                real capture sessions recording joined/left events on Harness.PubSub — start one,
                track and untrack flights, and watch the count climb until the 60s budget expires
                it. sessions observe from outside: they never appear in registry truth below.
                "exact" sessions use layer-2 call tracing (caller-attributed, no polling gap);
                unticked falls back to ≈ snapshot polling
              </p>
              <form
                class="flex items-center gap-3 flex-wrap"
                phx-change="arm_change"
                phx-submit="start_session"
              >
                <label class="flex items-center gap-1 text-sm cursor-pointer">
                  <input
                    type="checkbox"
                    name="trace"
                    checked={@arm_trace?}
                    class="checkbox checkbox-xs"
                  /> exact (call tracing)
                </label>
                <button class="btn btn-sm" type="submit">
                  start a session (60s budget)
                </button>
              </form>
              <ul class="font-mono text-sm space-y-1">
                <li :for={session <- @sessions} class="flex items-center gap-2">
                  {session.name}
                  <span class={["badge", badge_class(session.status)]}>{session.status}</span>
                  <span class="badge badge-outline">{if session.traced?, do: "exact", else: "≈ approx"}</span>
                  <span class="opacity-70">{session.events} events</span>
                  <button
                    :if={session.status == :running}
                    class="btn btn-xs"
                    phx-click="stop_session"
                    phx-value-session={session.name}
                  >
                    stop
                  </button>
                </li>
                <li :if={@sessions == []} class="opacity-60">
                  (no sessions yet — start one and click around)
                </li>
              </ul>
            </div>

            <div class="rounded border p-4 space-y-2">
              <h2 class="font-semibold">Registry truth</h2>
              <p class="text-sm opacity-70">
                what this LiveView pid is actually subscribed to, via Wiretap.snapshot/1 —
                walk off shift and watch the flights stay here while your scope reads empty
              </p>
              <ul class="font-mono text-sm space-y-1">
                <li :for={topic <- @my_subscriptions}>{topic}</li>
                <li :if={@my_subscriptions == []} class="opacity-60">(no subscriptions)</li>
              </ul>
            </div>
          </div>

          <div class="rounded border p-3 space-y-2 lg:overflow-y-auto">
            <h2 class="font-semibold">Received transmissions</h2>
            <p class="text-xs opacity-70">
              click an entry for the full report; "leaked" = not tracking that flight
            </p>
            <ul class="space-y-1">
              <li
                :for={entry <- @received}
                class="rounded px-2 py-1 cursor-pointer select-none font-mono text-xs hover:bg-base-200"
                phx-click="inspect"
                phx-value-id={entry.id}
              >
                <span class="opacity-60">{entry.received_at}</span>
                {entry.callsign} alt {entry.alt} hdg {entry.hdg}
                <span :if={entry.leaked?} class="badge badge-warning badge-xs">leaked</span>
              </li>
              <li :if={@received == []} class="opacity-60 text-sm">(nothing received yet)</li>
            </ul>
          </div>
        </div>
      </div>

      <div :if={@selected} class="modal modal-open">
        <div class="modal-box space-y-2">
          <h3 class="font-bold text-lg">{@selected.callsign} — transmission</h3>
          <ul class="font-mono text-sm space-y-1">
            <li>received at: {@selected.received_at} UTC</li>
            <li>aircraft: {@selected.type}</li>
            <li>route: {@selected.origin} → {@selected.destination}</li>
            <li>altitude: {@selected.alt} ft</li>
            <li>heading: {@selected.hdg}°</li>
            <li>ground speed: {@selected.gs} kts</li>
            <li>vertical rate: {@selected.vertical_rate} fpm</li>
            <li>squawk: {@selected.squawk}</li>
            <li>topic: flight:{@selected.callsign}</li>
            <li>
              tracked at receipt: {if @selected.leaked?, do: "no — leaked delivery", else: "yes"}
            </li>
          </ul>
          <div class="modal-action">
            <button class="btn" phx-click="close_modal">close</button>
          </div>
        </div>
        <div class="modal-backdrop cursor-pointer" phx-click="close_modal"></div>
      </div>
    </Layouts.app>
    """
  end
end
