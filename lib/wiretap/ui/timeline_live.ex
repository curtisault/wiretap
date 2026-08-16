if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Wiretap.UI.TimelineLive do
    @moduledoc false

    use Phoenix.LiveView

    alias Wiretap.UI.Layouts

    @coalesce_ms 250
    @render_cap 500

    @impl true
    def mount(_params, _session, socket) do
      {:ok,
       assign(socket,
         sessions: Wiretap.sessions(),
         selected: nil,
         events: [],
         total: 0,
         refresh_pending?: false
       )}
    end

    @impl true
    def handle_params(params, _uri, socket) do
      previous = socket.assigns.selected
      selected = find_session(params["session"])

      if (connected?(socket) and selected) && selected.name != previous do
        if previous, do: Phoenix.PubSub.unsubscribe(Wiretap.PubSub, nudge_topic(previous))
        :ok = Phoenix.PubSub.subscribe(Wiretap.PubSub, nudge_topic(selected.name))
      end

      {:noreply,
       socket
       |> assign(sessions: Wiretap.sessions(), selected: selected && selected.name)
       |> load_events()}
    end

    @impl true
    def handle_info({:wiretap_events, name, count}, socket) do
      socket = assign(socket, total: max(count, socket.assigns.total))

      if socket.assigns.refresh_pending? or name != socket.assigns.selected do
        {:noreply, socket}
      else
        Process.send_after(self(), :refresh, @coalesce_ms)
        {:noreply, assign(socket, refresh_pending?: true)}
      end
    end

    def handle_info(:refresh, socket) do
      {:noreply, socket |> assign(refresh_pending?: false) |> load_events()}
    end

    @impl true
    def handle_event("select", %{"session" => name}, socket) do
      {:noreply, push_patch(socket, to: "/timeline?session=#{name}")}
    end

    def handle_event("start_session", _params, socket) do
      case Wiretap.UI.pubsub() do
        nil ->
          {:noreply, socket}

        pubsub ->
          {:ok, name} = Wiretap.watch(pubsub)
          {:noreply, push_patch(socket, to: "/timeline?session=#{name}")}
      end
    end

    def handle_event("stop_session", _params, socket) do
      if socket.assigns.selected, do: Wiretap.stop(socket.assigns.selected)
      {:noreply, socket |> assign(sessions: Wiretap.sessions()) |> load_events()}
    end

    defp nudge_topic(name), do: "wiretap:session:" <> name

    defp find_session(nil), do: nil
    defp find_session(name), do: Enum.find(Wiretap.sessions(), &(&1.name == name))

    defp load_events(%{assigns: %{selected: nil}} = socket), do: assign(socket, events: [])

    defp load_events(%{assigns: %{selected: name}} = socket) do
      events = Wiretap.events(name)

      assign(socket,
        events: Enum.take(events, -@render_cap),
        total: max(socket.assigns.total, length(events))
      )
    end

    defp session_struct(socket) do
      Enum.find(socket.assigns.sessions, &(&1.name == socket.assigns.selected))
    end

    defp at_time(at) do
      at
      |> DateTime.from_unix!(:microsecond)
      |> Calendar.strftime("%H:%M:%S.%f")
    end

    defp approx?(event), do: event.source == :snapshot

    defp describe(%{kind: :telemetry} = event) do
      "#{inspect(event.meta.event)} #{event.payload_preview}"
    end

    defp describe(%{kind: :probe} = event) do
      ~s(#{event.topic} "#{event.meta.label}" #{inspect(event.meta.meta)})
    end

    defp describe(%{kind: :left_by_death} = event) do
      "#{event.topic} #{event.pid_label} (#{inspect(event.meta.reason)})"
    end

    defp describe(event), do: "#{event.topic} #{event.pid_label}"

    @impl true
    def render(assigns) do
      ~H"""
      <Layouts.nav active={:timeline} />
      <main class="wt-main">
        <div class="wt-panel-head">
          <h1>Timeline</h1>
          <form :if={@sessions != []} phx-change="select">
            <select name="session">
              <option value="" disabled selected={@selected == nil}>pick a session…</option>
              <option :for={s <- @sessions} value={s.name} selected={s.name == @selected}>
                {s.name} ({s.status})
              </option>
            </select>
          </form>
          <button :if={Wiretap.UI.pubsub()} class="wt-btn" phx-click="start_session">
            start session
          </button>
        </div>

        <Layouts.empty_state
          :if={@sessions == []}
          title="No capture sessions yet."
          body="A session polls the registry, diffs, and records joined/left events with budgets."
        >
          <:action>
            <button :if={Wiretap.UI.pubsub()} class="wt-btn" phx-click="start_session">
              start one
            </button>
          </:action>
        </Layouts.empty_state>

        <Layouts.empty_state
          :if={@sessions != [] and @selected == nil}
          title="Pick a session."
          body="Running and finished sessions both keep their events readable."
        />

        <%= if session = session_struct(assigns_to_socket(assigns)) do %>
          <div class="wt-session-bar">
            <span class={"wt-badge wt-#{session.status}"}>{session.status}</span>
            <span class="wt-dim">
              resolution ≈ {session.interval_ms}ms (snapshot polling) — exact timing and caller
              attribution arrive with trace sessions (v0.3)
            </span>
            <span :if={@total > length(@events)} class="wt-dim">
              showing last {length(@events)} of {@total}
            </span>
            <button :if={session.status == :running} class="wt-btn" phx-click="stop_session">
              stop
            </button>
          </div>

          <Layouts.empty_state
            :if={session.status == :expired and @events == []}
            title={"Session expired (budget) before capturing anything."}
            body="Widen max_events / max_duration_ms, or start a new session."
          />

          <Layouts.empty_state
            :if={session.status == :running and @events == []}
            title="Nothing captured yet."
            body="Subscribe or unsubscribe something on the watched PubSub and events appear here."
          />

          <div :if={@events != []} id="wiretap-timeline" class="wt-log" phx-hook="WiretapFollow">
            <div :for={event <- @events} class="wt-row">
              <span class="wt-time">{at_time(event.at)}</span>
              <span class={"wt-kind wt-kind-#{event.kind}"}>{event.kind}</span>
              <span :if={approx?(event)} class="wt-approx" title="approximate: seen by snapshot polling">≈</span>
              <span class="wt-desc">{describe(event)}</span>
            </div>
          </div>
          <button id="follow-pill" class="wt-pill hidden" type="button">
            ⤓ following paused — click to resume
          </button>
        <% end %>
      </main>
      """
    end

    # render/1 helpers work on assigns; session_struct expects socket-shaped input
    defp assigns_to_socket(assigns), do: %{assigns: assigns}
  end
end
