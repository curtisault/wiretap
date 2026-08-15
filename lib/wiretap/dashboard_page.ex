if Code.ensure_loaded?(Phoenix.LiveDashboard.PageBuilder) do
  defmodule Wiretap.DashboardPage do
    @moduledoc """
    LiveDashboard Roll Call page: topic → subscriber count → labeled pids.

    Deliberately frozen at read-only Roll Call (discovery B1) — richer panels
    belong to the standalone Wiretap UI. Compiled only when
    `phoenix_live_dashboard` is present.

    Install by passing the PubSub name in your dashboard route:

        live_dashboard "/dashboard",
          additional_pages: [wiretap: {Wiretap.DashboardPage, pubsub: MyApp.PubSub}]

    Rows come from `Wiretap.Snapshot.roll_call/1`, executed on the node
    selected in the dashboard's node switcher.
    """

    use Phoenix.LiveDashboard.PageBuilder

    alias Wiretap.Snapshot

    @impl true
    def init(opts) do
      pubsub =
        Keyword.get(opts, :pubsub) ||
          raise ArgumentError,
                "Wiretap.DashboardPage needs a :pubsub, e.g. " <>
                  "additional_pages: [wiretap: {Wiretap.DashboardPage, pubsub: MyApp.PubSub}]"

      {:ok, %{pubsub: pubsub}}
    end

    @impl true
    def menu_link(_session, _capabilities), do: {:ok, "Wiretap"}

    @impl true
    def mount(_params, %{pubsub: pubsub}, socket) do
      {:ok, assign(socket, pubsub: pubsub)}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.live_table
        id="wiretap-roll-call"
        dom_id="wiretap-roll-call"
        page={@page}
        title={"Roll Call (#{inspect(@pubsub)})"}
        row_fetcher={&fetch_rows(&1, &2, @pubsub)}
        rows_name="topics"
        default_sort_by={:subscribers}
      >
        <:col field={:topic} sortable={:asc} />
        <:col field={:subscribers} header="Subscribers" text_align="right" sortable={:desc} />
        <:col :let={row} field={:pids} header="Subscriber pids (labeled)">
          {Enum.join(row.pids, ", ")}
        </:col>
      </.live_table>
      """
    end

    @doc false
    @spec fetch_rows(map(), node(), atom()) :: {[map()], non_neg_integer()}
    def fetch_rows(params, node, pubsub) do
      %{search: search, sort_by: sort_by, sort_dir: sort_dir, limit: limit} = params

      rows =
        node
        |> fetch_roll_call(pubsub)
        |> filter(search)

      shown =
        rows
        |> Enum.sort_by(&Map.fetch!(&1, sort_by), sort_dir)
        |> Enum.take(limit)

      {shown, length(rows)}
    end

    defp fetch_roll_call(node, pubsub) when node == node(), do: Snapshot.roll_call(pubsub)
    defp fetch_roll_call(node, pubsub), do: :erpc.call(node, Snapshot, :roll_call, [pubsub])

    defp filter(rows, nil), do: rows
    defp filter(rows, search), do: Enum.filter(rows, &String.contains?(&1.topic, search))
  end
end
