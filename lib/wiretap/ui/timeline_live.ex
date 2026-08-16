if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Wiretap.UI.TimelineLive do
    @moduledoc false

    use Phoenix.LiveView

    alias Wiretap.UI.Layouts

    @coalesce_ms 250
    @render_cap 500

    @impl true
    def mount(_params, _session, socket) do
      if connected?(socket), do: Process.send_after(self(), :countdown_tick, 1_000)

      {:ok,
       assign(socket,
         sessions: Wiretap.sessions(),
         selected: nil,
         events: [],
         total: 0,
         refresh_pending?: false,
         arm_trace?: false,
         arm_prefixes: ""
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

    # 1s heartbeat: live countdown and status flips (running → expired) without
    # waiting for an event nudge.
    def handle_info(:countdown_tick, socket) do
      Process.send_after(self(), :countdown_tick, 1_000)
      {:noreply, assign(socket, sessions: Wiretap.sessions())}
    end

    @impl true
    def handle_event("select", %{"session" => name}, socket) do
      {:noreply, push_patch(socket, to: "/timeline?session=#{name}")}
    end

    def handle_event("arm_change", params, socket) do
      {:noreply,
       assign(socket,
         arm_trace?: params["trace"] == "on",
         arm_prefixes: params["prefixes"] || socket.assigns.arm_prefixes
       )}
    end

    def handle_event("start_session", _params, socket) do
      case Wiretap.UI.pubsub() do
        nil ->
          {:noreply, socket}

        pubsub ->
          opts =
            if socket.assigns.arm_trace?,
              do: [trace: [prefixes: parse_prefixes(socket.assigns.arm_prefixes)]],
              else: []

          {:ok, name} = Wiretap.watch(pubsub, opts)
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

    defp parse_prefixes(input) do
      input
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    end

    # B5: say exactly what arming will attach, before the confirm.
    defp arm_preview(false, _prefixes) do
      "will attach: registry snapshot polling (~1s, approximate) · budgets: 1000 ev / 60s / 250 ev/s"
    end

    defp arm_preview(true, prefixes) do
      scope =
        case parse_prefixes(prefixes) do
          [] -> "all topics"
          list -> "prefixes " <> Enum.join(list, ", ")
        end

      "will attach: call tracing on Phoenix.PubSub.subscribe/2,3 + unsubscribe/2 " <>
        "(#{scope}; exact, caller-attributed) + baseline monitors · budgets: 1000 ev / 60s / 250 ev/s"
    end

    defp resolution_chip(%{trace: false} = session) do
      "resolution ≈ #{session.interval_ms}ms (snapshot polling) — arm with trace for exact events"
    end

    defp resolution_chip(_traced_session) do
      "exact: call tracing armed (caller-attributed); deaths via monitors"
    end

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
        </div>

        <form
          :if={Wiretap.UI.pubsub()}
          class="wt-arm"
          phx-change="arm_change"
          phx-submit="start_session"
        >
          <label>
            <input type="checkbox" name="trace" checked={@arm_trace?} /> trace (exact events)
          </label>
          <input
            :if={@arm_trace?}
            type="text"
            name="prefixes"
            value={@arm_prefixes}
            placeholder="topic prefixes, comma-separated (optional)"
            phx-debounce="150"
          />
          <button class="wt-btn" type="submit">arm session</button>
          <span class="wt-dim wt-preview">{arm_preview(@arm_trace?, @arm_prefixes)}</span>
        </form>

        <Layouts.empty_state
          :if={@sessions == []}
          title="No capture sessions yet."
          body="A session records joined/left events with budgets — arm one above."
        />

        <Layouts.empty_state
          :if={@sessions != [] and @selected == nil}
          title="Pick a session."
          body="Running and finished sessions both keep their events readable."
        />

        <%= if session = session_struct(assigns_to_socket(assigns)) do %>
          <div class="wt-session-bar">
            <span class={"wt-badge wt-#{session.status}"}>{session.status}</span>
            <span class="wt-dim">{resolution_chip(session)}</span>
            <span class="wt-dim">
              {@total}/{session.max_events} events · cap {session.max_rate}/s
            </span>
            <span :if={session.status == :running} class="wt-dim">
              {div(Wiretap.Session.remaining_ms(session), 1000)}s left
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
