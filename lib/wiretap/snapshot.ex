defmodule Wiretap.Snapshot do
  @moduledoc """
  Layer 1: point-in-time views of a `Phoenix.PubSub` registry.

  Everything here is a pure read — `Registry.select/2` / `Registry.lookup/2`
  against the registry that `Phoenix.PubSub` maintains (its name is the PubSub
  name, e.g. `MyApp.PubSub`). No processes, no state, no writes to the host.

  Because the registry's entry format is semi-private to phoenix_pubsub,
  `probe/1` validates the observed shape before a session trusts this layer;
  callers arming a session must treat a probe failure as "layer unavailable"
  and say so loudly, never render silently wrong data.
  """

  @select_spec [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}]
  @probe_sample 100

  @typedoc "The name of a `Phoenix.PubSub` instance (also its registry name)."
  @type pubsub :: atom()

  @typedoc "A PubSub topic."
  @type topic :: String.t()

  @typedoc "Point-in-time view: topic → sorted subscriber pids."
  @type t :: %{topic() => [pid()]}

  @doc """
  Takes a snapshot of every subscription in `pubsub`.

  Returns a map of topic to sorted subscriber pids. A pid subscribed to the
  same topic more than once appears once per subscription, mirroring the
  registry's duplicate-key semantics.
  """
  @spec take(pubsub()) :: t()
  def take(pubsub) do
    pubsub
    |> Registry.select(@select_spec)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {topic, pids} -> {topic, Enum.sort(pids)} end)
  end

  @doc "All topics with at least one subscriber, sorted."
  @spec topics(pubsub()) :: [topic()]
  def topics(pubsub) do
    pubsub |> take() |> Map.keys() |> Enum.sort()
  end

  @doc "Sorted pids subscribed to `topic` right now."
  @spec subscribers(pubsub(), topic()) :: [pid()]
  def subscribers(pubsub, topic) do
    pubsub
    |> Registry.lookup(topic)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  @doc """
  Roll-call rows: one entry per topic with subscriber count and labeled pids.

  This is the headless equivalent of the Roll Call panel (and what the
  LiveDashboard page renders). Labels are computed on the node where the
  pids live, so call this via `:erpc` for remote nodes.
  """
  @spec roll_call(pubsub()) :: [
          %{topic: topic(), subscribers: non_neg_integer(), pids: [String.t()]}
        ]
  def roll_call(pubsub) do
    for {topic, pids} <- take(pubsub) do
      %{topic: topic, subscribers: length(pids), pids: Enum.map(pids, &label/1)}
    end
  end

  @typedoc "A roll-call row."
  @type roll_call_row :: %{topic: topic(), subscribers: non_neg_integer(), pids: [String.t()]}

  @typedoc "A roll-call group (single-level prefix grouping, discovery B4)."
  @type roll_call_group :: %{
          label: String.t(),
          prefix: String.t() | nil,
          subscribers: non_neg_integer(),
          topics: [roll_call_row()]
        }

  @doc """
  Grouped roll call: `roll_call(pubsub, group: ":")` groups topics sharing a
  first `":"`-segment (when the group has ≥ 2 members) into
  `%{label: "station:*", …}` entries; singletons stay flat. Groups and their
  topics sort by subscriber count, descending.
  """
  @spec roll_call(pubsub(), keyword()) :: [roll_call_group()]
  def roll_call(pubsub, opts) do
    group(roll_call(pubsub), Keyword.fetch!(opts, :group))
  end

  @doc "Groups roll-call rows by first prefix segment. Pure; see `roll_call/2`."
  @spec group([roll_call_row()], String.t()) :: [roll_call_group()]
  def group(rows, separator) do
    rows
    |> Enum.group_by(fn row ->
      case String.split(row.topic, separator, parts: 2) do
        [prefix, _rest] -> prefix
        [_no_separator] -> nil
      end
    end)
    |> Enum.flat_map(fn
      {nil, singles} -> Enum.map(singles, &singleton_group/1)
      {_prefix, [single]} -> [singleton_group(single)]
      {prefix, members} -> [prefix_group(prefix, separator, members)]
    end)
    |> Enum.sort_by(& &1.subscribers, :desc)
  end

  defp singleton_group(row) do
    %{label: row.topic, prefix: nil, subscribers: row.subscribers, topics: [row]}
  end

  defp prefix_group(prefix, separator, members) do
    %{
      label: prefix <> separator <> "*",
      prefix: prefix,
      subscribers: members |> Enum.map(& &1.subscribers) |> Enum.sum(),
      topics: Enum.sort_by(members, & &1.subscribers, :desc)
    }
  end

  @doc """
  Diffs two snapshots into `:joined` / `:left` edges.

  An edge is a `{topic, pid}` pair present in one snapshot and absent from the
  other. Ordering within the lists is unspecified.
  """
  @spec diff(t(), t()) :: %{joined: [{topic(), pid()}], left: [{topic(), pid()}]}
  def diff(old, new) do
    %{joined: edges(new, old), left: edges(old, new)}
  end

  defp edges(side, other_side) do
    Enum.flat_map(side, fn {topic, pids} ->
      absent_from_other(topic, pids, Map.get(other_side, topic))
    end)
  end

  defp absent_from_other(topic, pids, nil), do: Enum.map(pids, &{topic, &1})

  defp absent_from_other(topic, pids, other_pids) do
    other_set = MapSet.new(other_pids)
    for pid <- pids, not MapSet.member?(other_set, pid), do: {topic, pid}
  end

  @doc """
  Verifies that `pubsub` names a registry whose entries have the shape this
  module assumes (`{topic :: binary, pid}` rows from the select spec).

  Passive-first per discovery A1: a select smoke test plus shape validation on
  a sample of up to #{@probe_sample} rows. An empty registry validates
  optimistically. Callers must surface a failure loudly (log + telemetry +
  UI state) and mark layer 1 unavailable — this function only reports.
  """
  @spec probe(pubsub()) :: :ok | {:error, :no_registry | :unrecognized_shape}
  def probe(pubsub) do
    rows =
      try do
        pubsub |> Registry.select(@select_spec) |> Enum.take(@probe_sample)
      rescue
        _ -> :no_registry
      catch
        :exit, _ -> :no_registry
      end

    case rows do
      :no_registry ->
        {:error, :no_registry}

      rows ->
        if Enum.all?(rows, &well_shaped?/1), do: :ok, else: {:error, :unrecognized_shape}
    end
  end

  defp well_shaped?({topic, pid}) when is_binary(topic) and is_pid(pid), do: true
  defp well_shaped?(_row), do: false

  @doc """
  Best single-identity label for a pid, per discovery A9.

  Precedence: registered name → process label (`:proc_lib.set_label/1`) →
  `:"$initial_call"` module, with `Phoenix.LiveView.Channel` rendered as
  `"LiveView"` → `inspect(pid)`. Binary process labels are used verbatim;
  other terms are inspected. Ancestor/caller chains are deliberately not
  part of the label — they belong to the (future) Process Inspector.
  """
  @spec label(pid()) :: String.t()
  def label(pid) when is_pid(pid) do
    case Process.info(pid, [:registered_name, :dictionary]) do
      nil -> inspect(pid)
      info -> build_label(pid, info[:registered_name], info[:dictionary])
    end
  end

  defp build_label(_pid, name, _dict) when is_atom(name), do: inspect(name)

  defp build_label(pid, _unregistered, dict) do
    case List.keyfind(dict, :"$process_label", 0) do
      {_, process_label} when is_binary(process_label) -> process_label
      {_, process_label} -> inspect(process_label)
      nil -> initial_call_label(pid, dict)
    end
  end

  defp initial_call_label(pid, dict) do
    case List.keyfind(dict, :"$initial_call", 0) do
      {_, {Phoenix.LiveView.Channel, _fun, _arity}} -> "LiveView"
      {_, {mod, _fun, _arity}} -> inspect(mod)
      _ -> inspect(pid)
    end
  end
end
