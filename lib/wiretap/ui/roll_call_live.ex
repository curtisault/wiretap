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
       |> assign(pubsub: Wiretap.UI.pubsub(), filter: "", expanded: MapSet.new())
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

          assign(socket, probe: :ok, groups: groups)

        {:error, reason} ->
          assign(socket, probe: reason, groups: [])
      end
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
                class={group.prefix && "wt-member"}
              >
                <td>{row.topic}</td>
                <td class="num">{row.subscribers}</td>
                <td class="wt-dim">{Enum.join(row.pids, ", ")}</td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </main>
      """
    end
  end
end
