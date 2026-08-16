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
