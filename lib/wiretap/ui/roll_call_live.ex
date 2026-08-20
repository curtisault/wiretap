if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Wiretap.UI.RollCallLive do
    @moduledoc false

    use Phoenix.LiveView

    alias Wiretap.Snapshot
    alias Wiretap.SysInspector
    alias Wiretap.UI.Layouts

    @refresh_ms 1_000

    @impl true
    def mount(_params, _session, socket) do
      if connected?(socket), do: schedule()

      {:ok,
       socket
       |> assign(
         pubsub: Wiretap.UI.pubsub(),
         filter: "",
         expanded: MapSet.new(),
         selected_topic: nil,
         broadcast_tree: nil,
         inspected: nil,
         sys_feed: [],
         sys_watch: nil,
         vitals: nil
       )
       |> load()}
    end

    @impl true
    def handle_info(:refresh, socket) do
      schedule()
      {:noreply, socket |> load() |> refresh_vitals()}
    end

    # Inspector feed: the SysInspector debug fun forwards :sys events here.
    def handle_info({:wiretap_sys_event, pid, event}, socket) do
      if match?(%{pid: ^pid}, socket.assigns.inspected) do
        entry = %{at: Time.truncate(Time.utc_now(), :millisecond), text: SysInspector.describe_event(event)}
        {:noreply, assign(socket, sys_feed: Enum.take([entry | socket.assigns.sys_feed], 50))}
      else
        {:noreply, socket}
      end
    end

    @impl true
    def terminate(_reason, socket) do
      close_inspector(socket)
      :ok
    end

    defp close_inspector(socket) do
      case Map.get(socket.assigns, :sys_watch) do
        {pid, id} -> SysInspector.stop_watching(pid, id)
        _ -> :ok
      end

      assign(socket, inspected: nil, sys_feed: [], sys_watch: nil, vitals: nil)
    end

    # Vitals ride the existing 1s refresh: open pane = sampled, closed = free.
    defp refresh_vitals(%{assigns: %{inspected: %{pid: pid}}} = socket) do
      assign(socket, vitals: sample_vitals(pid, socket.assigns.vitals))
    end

    defp refresh_vitals(socket), do: socket

    defp sample_vitals(pid, prev) do
      case SysInspector.vitals(pid) do
        {:ok, vitals} ->
          delta =
            case prev do
              %{reductions: r} -> vitals.reductions - r
              _ -> nil
            end

          Map.put(vitals, :reductions_delta, delta)

        {:error, :not_alive} ->
          :gone
      end
    end

    @impl true
    def handle_event("filter", %{"q" => q}, socket) do
      {:noreply, socket |> assign(filter: q) |> load()}
    end

    def handle_event("inspect_topic", %{"topic" => topic}, socket) do
      {:noreply, assign(socket, selected_topic: topic_details(socket.assigns.pubsub, topic))}
    end

    def handle_event("close_topic", _params, socket) do
      {:noreply,
       socket
       |> close_inspector()
       |> assign(selected_topic: nil, broadcast_tree: nil)}
    end

    # Process Inspector (4.2): compliance is detected before any :sys call —
    # raw pids get an honest refusal pane, never a hanging :sys.install.
    def handle_event("inspect_pid", %{"idx" => idx}, socket) do
      sub = Enum.at(socket.assigns.selected_topic.subscribers, String.to_integer(idx))

      case sub && SysInspector.peek(sub.pid) do
        {:ok, info} ->
          watch =
            case SysInspector.watch_messages(sub.pid, self()) do
              {:ok, id} -> {sub.pid, id}
              _ -> nil
            end

          {:noreply,
           assign(socket,
             inspected: info,
             sys_feed: [],
             sys_watch: watch,
             vitals: sample_vitals(sub.pid, nil)
           )}

        {:error, reason} ->
          # vitals need no :sys — the one reading a non-OTP pid can still give
          inspected = %{pid: sub.pid, label: sub.label, error: reason}

          {:noreply,
           assign(socket,
             inspected: inspected,
             sys_feed: [],
             sys_watch: nil,
             vitals: sample_vitals(sub.pid, nil)
           )}

        nil ->
          {:noreply, socket}
      end
    end

    def handle_event("close_inspector", _params, socket) do
      {:noreply, close_inspector(socket)}
    end

    # Broadcast Trace (3b): injected by design — wiretap sends the stamped
    # broadcast itself; the tree follows the token through relays.
    def handle_event("trace_broadcast", %{"payload" => payload}, socket) do
      result =
        Wiretap.trace_broadcast(
          socket.assigns.pubsub,
          socket.assigns.selected_topic.topic,
          {:wiretap_trace, payload}
        )

      {:noreply, assign(socket, broadcast_tree: result)}
    end

    # B2 funnel: tap a subscriber straight from the topic inspector — starts a
    # session with :receive tracing on that pid and lands on its Timeline.
    def handle_event("tap_pid", %{"idx" => idx}, socket) do
      sub = Enum.at(socket.assigns.selected_topic.subscribers, String.to_integer(idx))

      case sub && Wiretap.watch(socket.assigns.pubsub, tap: [sub.pid]) do
        {:ok, session} ->
          {:noreply, push_navigate(socket, to: "/timeline?session=#{session}")}

        _ ->
          {:noreply, socket}
      end
    end

    def handle_event("toggle_group", %{"label" => label}, socket) do
      expanded = socket.assigns.expanded

      expanded =
        if MapSet.member?(expanded, label),
          do: MapSet.delete(expanded, label),
          else: MapSet.put(expanded, label)

      {:noreply, assign(socket, expanded: expanded)}
    end

    defp schedule, do: Process.send_after(self(), :refresh, @refresh_ms)

    defp load(%{assigns: %{pubsub: nil}} = socket) do
      assign(socket, probe: :no_pubsub_configured, groups: [])
    end

    defp load(%{assigns: %{pubsub: pubsub, filter: filter}} = socket) do
      case Snapshot.probe(pubsub) do
        :ok ->
          groups =
            pubsub
            |> Snapshot.roll_call()
            |> filter_rows(filter)
            |> Snapshot.group(":")

          # keep an open topic inspector live-updating with the poll
          selected_topic =
            case Map.get(socket.assigns, :selected_topic) do
              %{topic: topic} -> topic_details(pubsub, topic)
              _ -> nil
            end

          assign(socket, probe: :ok, groups: groups, selected_topic: selected_topic)

        {:error, reason} ->
          assign(socket, probe: reason, groups: [])
      end
    end

    # Composed entirely from public functions (B9): subscribers/2, label/1, take/1.
    defp topic_details(pubsub, topic) do
      snapshot = Snapshot.take(pubsub)
      pids = Map.get(snapshot, topic, [])

      subscribers =
        for pid <- pids do
          other_topics =
            snapshot
            |> Enum.filter(fn {t, ps} -> t != topic and pid in ps end)
            |> Enum.map(fn {t, _ps} -> t end)
            |> Enum.sort()

          %{
            pid: pid,
            label: Snapshot.label(pid),
            alive?: Process.alive?(pid),
            other_topics: other_topics
          }
        end

      %{topic: topic, subscribers: subscribers}
    end

    defp more_topics(other_topics) do
      if length(other_topics) > 6, do: " … +#{length(other_topics) - 6} more", else: ""
    end

    defp filter_rows(rows, ""), do: rows
    defp filter_rows(rows, q), do: Enum.filter(rows, &String.contains?(&1.topic, q))

    @impl true
    def render(assigns) do
      ~H"""
      <Layouts.nav active={:roll_call} />
      <main class="wt-main">
        <div class="wt-panel-head">
          <h1>Roll Call <span :if={@pubsub} class="wt-dim">{inspect(@pubsub)}</span></h1>
          <form id="wt-rollcall-filter" phx-change="filter">
            <input type="text" name="q" value={@filter} placeholder="filter topics…" phx-debounce="150" />
          </form>
        </div>

        <Layouts.empty_state
          :if={@probe == :no_pubsub_configured}
          title="No PubSub configured."
          body="Tell the UI what to observe: config :wiretap, ui: [port: 5556, pubsub: MyApp.PubSub]"
        />

        <Layouts.empty_state
          :if={@probe not in [:ok, :no_pubsub_configured]}
          title={"Layer 1 unavailable for #{inspect(@pubsub)}: #{inspect(@probe)}"}
          body="The registry failed the shape probe — wiretap refuses to report data it cannot trust."
        />

        <Layouts.empty_state
          :if={@probe == :ok and @groups == [] and @filter == ""}
          title={"Nobody is subscribed to anything on #{inspect(@pubsub)}."}
          body="If you expected subscribers, check that this is the right PubSub instance."
        />

        <Layouts.empty_state
          :if={@probe == :ok and @groups == [] and @filter != ""}
          title={"Nobody is listening to \"#{@filter}\"."}
          body="No topic matches the filter. The Timeline can catch future subscribers the moment they join."
        >
          <:action>
            <.link navigate="/timeline" class="wt-btn">watch for subscribers →</.link>
          </:action>
        </Layouts.empty_state>

        <table :if={@groups != []} class="wt-table">
          <thead>
            <tr>
              <th>topic</th>
              <th class="num">subscribers</th>
              <th>pids</th>
            </tr>
          </thead>
          <tbody>
            <%= for group <- @groups do %>
              <tr
                :if={group.prefix}
                class="wt-group"
                phx-click="toggle_group"
                phx-value-label={group.label}
              >
                <td>
                  <span class="wt-caret">{if MapSet.member?(@expanded, group.label), do: "▾", else: "▸"}</span>
                  {group.label} <span class="wt-dim">({length(group.topics)} topics)</span>
                </td>
                <td class="num">{group.subscribers}</td>
                <td></td>
              </tr>
              <tr
                :for={row <- group.topics}
                :if={group.prefix == nil or MapSet.member?(@expanded, group.label)}
                class={["wt-clickable", group.prefix && "wt-member"]}
                phx-click="inspect_topic"
                phx-value-topic={row.topic}
                title="click for the topic's subscribers"
              >
                <td>{row.topic}</td>
                <td class="num">{row.subscribers}</td>
                <td class="wt-dim">{Enum.join(row.pids, ", ")}</td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </main>

      <div :if={@selected_topic} class="wt-modal">
        <div class="wt-modal-backdrop" phx-click="close_topic"></div>
        <div class="wt-modal-box">
          <h3>{@selected_topic.topic}</h3>
          <p class="wt-dim">
            {length(@selected_topic.subscribers)} subscriber(s) — live, updates with the poll
          </p>

          <p :if={@selected_topic.subscribers == []} class="wt-dim">
            (nobody is subscribed to this topic anymore)
          </p>

          <table :if={@selected_topic.subscribers != []} class="wt-detail">
            <tbody>
              <tr :for={{sub, idx} <- Enum.with_index(@selected_topic.subscribers)}>
                <td>{inspect(sub.pid)}</td>
                <td>
                  {sub.label}
                  <span :if={not sub.alive?} class="wt-approx">dead</span>
                  <div :if={sub.other_topics != []} class="wt-dim">
                    also subscribed: {Enum.join(Enum.take(sub.other_topics, 6), ", ")}{more_topics(
                      sub.other_topics
                    )}
                  </div>
                </td>
                <td>
                  <button
                    :if={sub.alive?}
                    class="wt-btn"
                    phx-click="tap_pid"
                    phx-value-idx={idx}
                    title="start a session capturing EVERYTHING this pid receives — taps are per-pid, not per-topic (delivered messages carry no topic)"
                  >
                    tap messages
                  </button>
                  <button
                    :if={sub.alive?}
                    class="wt-btn"
                    phx-click="inspect_pid"
                    phx-value-idx={idx}
                    title="read this process through :sys — state, ancestry, live message feed"
                  >
                    inspect
                  </button>
                </td>
              </tr>
            </tbody>
          </table>

          <div class="wt-trace-bc">
            <h4>Broadcast Trace</h4>
            <p class="wt-dim">
              wiretap sends a stamped test broadcast on this topic and maps the delivery
              tree — relays included. (Tokens cannot be injected into organic broadcasts.)
            </p>
            <form phx-submit="trace_broadcast">
              <input type="text" name="payload" value="wiretap test" />
              <button class="wt-btn" type="submit">send + trace</button>
            </form>

            <%= case @broadcast_tree do %>
              <% nil -> %>
              <% {:error, :foreign_tracer} -> %>
                <p class="wt-approx">
                  another tool owns the seq_trace system tracer — refusing to clobber it
                </p>
              <% {:ok, %{hops: []}} -> %>
                <p class="wt-approx">
                  delivered to nobody — this topic is not wired to anything right now
                </p>
              <% {:ok, tree} -> %>
                <ul class="wt-tree">
                  <li :for={hop <- tree.hops} style={"padding-left: #{hop.depth}rem"}>
                    <span class="wt-dim">+{hop.delta_us}µs</span>
                    {hop.from_label} → <b>{hop.to_label}</b>
                    <span class="wt-dim">{hop.message_preview}</span>
                  </li>
                </ul>
                <p class="wt-dim">
                  {length(tree.hops)} deliveries · depth {Enum.max(Enum.map(tree.hops, & &1.depth))}
                </p>
            <% end %>
          </div>

          <p class="wt-dim wt-headless-hint">
            headless twin: Wiretap.subscribers({inspect(@pubsub)}, "{@selected_topic.topic}")
            · Wiretap.trace_broadcast({inspect(@pubsub)}, "{@selected_topic.topic}", msg)
          </p>
          <button class="wt-btn" phx-click="close_topic">close</button>
        </div>
      </div>

      <div :if={@inspected} class="wt-modal wt-inspector">
        <div class="wt-modal-backdrop" phx-click="close_inspector"></div>
        <div class="wt-modal-box">
          <h3>{@inspected.label} <span class="wt-dim">{inspect(@inspected.pid)}</span></h3>

          <%= case @vitals do %>
            <% :gone -> %>
              <p class="wt-approx">process is gone</p>
            <% %{} = v -> %>
              <table class="wt-detail wt-vitals">
                <tbody>
                  <tr>
                    <td>vitals</td>
                    <td>
                      {human_bytes(v.memory)}
                      <span class="wt-dim">(heap {human_bytes(v.total_heap_size)})</span>
                      · queue {v.message_queue_len} · {v.status}
                    </td>
                  </tr>
                  <tr>
                    <td>reductions</td>
                    <td>
                      {v.reductions}
                      <span :if={v.reductions_delta} class="wt-dim">
                        (+{v.reductions_delta}/s)
                      </span>
                    </td>
                  </tr>
                </tbody>
              </table>
            <% _ -> %>
          <% end %>

          <%= if Map.has_key?(@inspected, :error) do %>
            <p class="wt-approx">
              {describe_peek_error(@inspected.error)}
            </p>
          <% else %>
            <table class="wt-detail">
              <tbody>
                <tr>
                  <td>initial call</td>
                  <td>{format_mfa(@inspected.initial_call)}</td>
                </tr>
                <tr>
                  <td>queue length</td>
                  <td>{@inspected.message_queue_len}</td>
                </tr>
                <tr :if={@inspected.ancestors != []}>
                  <td>ancestors</td>
                  <td>{Enum.join(@inspected.ancestors, " → ")}</td>
                </tr>
                <tr :if={@inspected.callers != []}>
                  <td>callers</td>
                  <td>{Enum.join(@inspected.callers, " → ")}</td>
                </tr>
                <tr>
                  <td>state</td>
                  <td>
                    <pre :if={@inspected.state_preview}>{@inspected.state_preview}</pre>
                    <span :if={is_nil(@inspected.state_preview)} class="wt-approx">
                      no answer within 200ms — the process is busy; chains above are still real
                    </span>
                  </td>
                </tr>
              </tbody>
            </table>

            <div class="wt-sys-feed">
              <h4>live message feed <span class="wt-dim">(:sys events, capped at 50)</span></h4>
              <p :if={@sys_feed == []} class="wt-dim">
                waiting for messages — the hook is removed the moment you close this pane
              </p>
              <ul :if={@sys_feed != []}>
                <li :for={entry <- @sys_feed}>
                  <span class="wt-dim">{entry.at}</span> {entry.text}
                </li>
              </ul>
            </div>
          <% end %>

          <p class="wt-dim wt-headless-hint">
            headless twin: Wiretap.peek(pid) · Wiretap.SysInspector.watch_messages(pid)
            · Wiretap.SysInspector.vitals(pid)
          </p>
          <button class="wt-btn" phx-click="close_inspector">close</button>
        </div>
      </div>
      """
    end

    defp describe_peek_error(:not_otp_compliant) do
      "this process doesn't speak the :sys protocol (no $initial_call) — " <>
        "a raw spawn can't be inspected, only tapped"
    end

    defp describe_peek_error(:not_alive), do: "this process is gone"
    defp describe_peek_error(other), do: inspect(other)

    defp format_mfa({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
    defp format_mfa(other), do: inspect(other)

    defp human_bytes(b) when b >= 1_048_576, do: "#{Float.round(b / 1_048_576, 1)} MB"
    defp human_bytes(b) when b >= 1_024, do: "#{Float.round(b / 1_024, 1)} KB"
    defp human_bytes(b), do: "#{b} B"
  end
end
