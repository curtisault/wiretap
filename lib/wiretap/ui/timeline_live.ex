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
         arm_prefixes: "",
         selected_event: nil,
         q: ""
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
       |> assign(
         sessions: Wiretap.sessions(),
         selected: selected && selected.name,
         selected_event: nil,
         q: params["q"] || socket.assigns.q
       )
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

    def handle_event("inspect", %{"seq" => seq}, socket) do
      seq = String.to_integer(seq)
      {:noreply, assign(socket, selected_event: Enum.find(socket.assigns.events, &(&1.seq == seq)))}
    end

    def handle_event("close_inspect", _params, socket) do
      {:noreply, assign(socket, selected_event: nil)}
    end

    def handle_event("filter", %{"q" => q}, socket) do
      {:noreply, assign(socket, q: q)}
    end

    def handle_event("clear_filter", _params, socket) do
      {:noreply, assign(socket, q: "")}
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

    defp at_iso(at) do
      at |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()
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

    defp describe(%{kind: :message} = event) do
      "#{event.pid_label} ← #{event.payload_preview || "(payloads off)"}"
    end

    defp describe(event), do: "#{event.topic} #{event.pid_label}"

    # Display filter only — capture is untouched (headless twin:
    # Wiretap.events(s) |> Enum.filter/2). Matches what the row shows.
    defp filter_events(events, ""), do: events

    defp filter_events(events, q) do
      needle = String.downcase(q)

      Enum.filter(events, fn event ->
        haystack = "#{event.kind} #{event.topic} #{describe(event)}"
        String.contains?(String.downcase(haystack), needle)
      end)
    end

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
          <% visible = filter_events(@events, @q) %>
          <div class="wt-session-bar">
            <%!-- notes line: free to appear/change without reflowing the controls --%>
            <div class="wt-session-notes wt-dim">
              <span>{resolution_chip(session)}</span>
              <span :if={session.tap != []}>
                tap = everything the pid receives — delivered messages carry no topic
              </span>
            </div>
            <%!-- filter left · events/cap centered · badge right, just above the table --%>
            <div class="wt-session-controls">
              <div class="wt-controls-left">
                <button :if={session.status == :running} class="wt-btn" phx-click="stop_session">
                  stop
                </button>
                <form id="wt-timeline-filter" phx-change="filter">
                  <input
                    type="text"
                    name="q"
                    value={@q}
                    placeholder="filter events…"
                    phx-debounce="150"
                  />
                </form>
                <span :if={@q != ""} class="wt-dim">
                  filter "{@q}": {length(visible)} of {length(@events)} shown
                </span>
              </div>
              <div class="wt-controls-center wt-dim">
                {@total}/{session.max_events} events · cap {session.max_rate}/s<span
                  :if={session.status == :running}
                  class="wt-countdown"
                > · {div(Wiretap.Session.remaining_ms(session), 1000)}s left</span>
              </div>
              <span class={"wt-badge wt-#{session.status}"}>{session.status}</span>
            </div>
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

          <Layouts.empty_state
            :if={@events != [] and visible == []}
            title={"Nothing matches \"#{@q}\"."}
            body={"#{length(@events)} captured events are hidden by the filter — display only, capture is untouched."}
          >
            <:action>
              <button class="wt-btn" phx-click="clear_filter">clear filter</button>
            </:action>
          </Layouts.empty_state>

          <div :if={visible != []} id="wiretap-timeline" class="wt-log" phx-hook="WiretapFollow">
            <div
              :for={event <- visible}
              class="wt-row wt-clickable"
              phx-click="inspect"
              phx-value-seq={event.seq}
              title="click for the full event"
            >
              <span class="wt-time">{at_time(event.at)}</span>
              <span class={"wt-kind wt-kind-#{event.kind}"}>{event.kind}</span>
              <span :if={approx?(event)} class="wt-approx" title="approximate: seen by snapshot polling">≈</span>
              <span class="wt-desc">{describe(event)}</span>
            </div>
          </div>
          <button id="follow-pill" class="wt-pill hidden" type="button">
            ⤓ following paused — click to resume
          </button>

          <%!-- permanent, so it never pops in and out (the counter updates
               instantly; rows reload on the 250ms coalesce — a conditional
               note here flickers in that gap) --%>
          <p :if={@events != []} class="wt-dim wt-shown-count">
            showing {length(visible)} of {@total} captured events
          </p>
        <% end %>
      </main>

      <div :if={@selected_event} class="wt-modal">
        <div class="wt-modal-backdrop" phx-click="close_inspect"></div>
        <div class="wt-modal-box">
          <h3>event #{@selected_event.seq} — {@selected_event.kind}</h3>
          <table class="wt-detail">
            <tbody>
              <tr>
                <td>at</td>
                <td>{at_iso(@selected_event.at)}</td>
              </tr>
              <tr>
                <td>kind</td>
                <td>{@selected_event.kind}</td>
              </tr>
              <tr>
                <td>source</td>
                <td>
                  {@selected_event.source}
                  <span :if={approx?(@selected_event)} class="wt-approx">
                    ≈ approximate (snapshot polling)
                  </span>
                </td>
              </tr>
              <tr :if={@selected_event.topic}>
                <td>topic</td>
                <td>{@selected_event.topic}</td>
              </tr>
              <tr :if={@selected_event.pid}>
                <td>pid</td>
                <td>{inspect(@selected_event.pid)} ({@selected_event.pid_label})</td>
              </tr>
              <tr :if={@selected_event.payload_preview}>
                <td>payload</td>
                <td><pre>{@selected_event.payload_preview}</pre></td>
              </tr>
              <tr :if={map_size(@selected_event.meta) > 0}>
                <td>meta</td>
                <td><pre>{inspect(@selected_event.meta, pretty: true, width: 60)}</pre></td>
              </tr>
              <tr>
                <td>session</td>
                <td>{@selected_event.session}</td>
              </tr>
            </tbody>
          </table>
          <p class="wt-dim wt-headless-hint">
            headless twin: Wiretap.events("{@selected_event.session}")
            |> Enum.find(&amp;(&amp;1.seq == {@selected_event.seq}))
          </p>
          <button class="wt-btn" phx-click="close_inspect">close</button>
        </div>
      </div>
      """
    end

    # render/1 helpers work on assigns; session_struct expects socket-shaped input
    defp assigns_to_socket(assigns), do: %{assigns: assigns}
  end
end
