if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Wiretap.UI.RollCallLive do
    @moduledoc false

    use Phoenix.LiveView

    alias Wiretap.Snapshot
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
         selected_topic: nil
       )
       |> load()}
    end

    @impl true
    def handle_info(:refresh, socket) do
      schedule()
      {:noreply, load(socket)}
    end

    @impl true
    def handle_event("filter", %{"q" => q}, socket) do
      {:noreply, socket |> assign(filter: q) |> load()}
    end

    def handle_event("inspect_topic", %{"topic" => topic}, socket) do
      {:noreply, assign(socket, selected_topic: topic_details(socket.assigns.pubsub, topic))}
    end

    def handle_event("close_topic", _params, socket) do
      {:noreply, assign(socket, selected_topic: nil)}
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
          <form phx-change="filter">
            <input type="text" name="q" value={@filter} placeholder="filter topics…" phx-debounce="150" />
          </form>
        </div>

        <Layouts.empty_state
          :if={@probe == :no_pubsub_configured}
          title="No PubSub configured."
          body="Tell the UI what to observe: config :wiretap, ui: [port: 4008, pubsub: MyApp.PubSub]"
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
                    title="start a session capturing every message this pid receives"
                  >
                    tap messages
                  </button>
                </td>
              </tr>
            </tbody>
          </table>

          <p class="wt-dim wt-headless-hint">
            headless twin: Wiretap.subscribers({inspect(@pubsub)}, "{@selected_topic.topic}")
          </p>
          <button class="wt-btn" phx-click="close_topic">close</button>
        </div>
      </div>
      """
    end
  end
end
