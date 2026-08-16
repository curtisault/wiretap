if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Wiretap.UI.SessionsLive do
    @moduledoc false

    use Phoenix.LiveView

    alias Wiretap.UI.Layouts

    @impl true
    def mount(_params, _session, socket) do
      if connected?(socket), do: Process.send_after(self(), :tick, 1_000)
      {:ok, load(socket)}
    end

    @impl true
    def handle_info(:tick, socket) do
      Process.send_after(self(), :tick, 1_000)
      {:noreply, load(socket)}
    end

    @impl true
    def handle_event("open", %{"session" => name}, socket) do
      {:noreply, push_navigate(socket, to: "/timeline?session=#{name}")}
    end

    defp load(socket) do
      rows =
        for session <- Wiretap.sessions() do
          %{
            session: session,
            events: length(Wiretap.events(session.name)),
            remaining_s: div(Wiretap.Session.remaining_ms(session), 1_000)
          }
        end

      assign(socket, rows: rows)
    end

    @impl true
    def render(assigns) do
      ~H"""
      <Layouts.nav active={:sessions} />
      <main class="wt-main">
        <div class="wt-panel-head">
          <h1>Sessions</h1>
          <span class="wt-dim">
            every session this node has seen — click a row for its timeline
          </span>
        </div>

        <Layouts.empty_state
          :if={@rows == []}
          title="No capture sessions yet."
          body="Arm one on the Timeline — or from iex: Wiretap.watch(MyApp.PubSub, trace: true)"
        >
          <:action>
            <.link navigate="/timeline" class="wt-btn">go to the Timeline →</.link>
          </:action>
        </Layouts.empty_state>

        <table :if={@rows != []} class="wt-table">
          <thead>
            <tr>
              <th>session</th>
              <th>status</th>
              <th>mode</th>
              <th>pubsub</th>
              <th class="num">events</th>
              <th>budgets</th>
              <th>remaining</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={row <- @rows}
              class="wt-clickable"
              phx-click="open"
              phx-value-session={row.session.name}
              title="open in the Timeline"
            >
              <td>{row.session.name}</td>
              <td>
                <span class={"wt-badge wt-#{row.session.status}"}>{row.session.status}</span>
              </td>
              <td>{if row.session.trace, do: "exact", else: "≈ snapshot"}</td>
              <td class="wt-dim">{inspect(row.session.pubsub)}</td>
              <td class="num">{row.events}</td>
              <td class="wt-dim">
                {row.session.max_events} ev · {div(row.session.max_duration_ms, 1_000)}s
                · {row.session.max_rate}/s
              </td>
              <td class="wt-dim">
                {if row.session.status == :running, do: "#{row.remaining_s}s", else: "—"}
              </td>
            </tr>
          </tbody>
        </table>

        <p class="wt-dim wt-headless-hint">headless twin: Wiretap.sessions()</p>
      </main>
      """
    end
  end
end
