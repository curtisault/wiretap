defmodule Wiretap.Session do
  @moduledoc """
  A capture session: what is being watched, with which budgets, in which state.

  Budgets are the safety contract (§8.2): every session carries a maximum
  event count and a maximum duration, and hitting either bound expires the
  session automatically. Defaults are deliberately conservative — widen them
  per session, consciously.
  """

  @enforce_keys [:name, :pubsub]
  defstruct [
    :name,
    :pubsub,
    :started_at,
    interval_ms: 1_000,
    max_events: 1_000,
    max_duration_ms: 60_000,
    status: :running
  ]

  @type status :: :running | :stopped | :expired | :crashed

  @type t :: %__MODULE__{
          name: String.t(),
          pubsub: atom(),
          started_at: integer() | nil,
          interval_ms: pos_integer(),
          max_events: pos_integer(),
          max_duration_ms: pos_integer(),
          status: status()
        }

  @doc """
  Builds a session for `pubsub`.

  Options: `:name` (defaults to a generated `"wiretap-<random hex>"`, unique
  across VM restarts), `:interval_ms` (default 1000 — see discovery A4),
  `:max_events` (default 1000), `:max_duration_ms` (default 60_000).
  """
  @spec new(atom(), keyword()) :: t()
  def new(pubsub, opts \\ []) do
    %__MODULE__{
      name: Keyword.get_lazy(opts, :name, &generate_name/0),
      pubsub: pubsub,
      interval_ms: Keyword.get(opts, :interval_ms, 1_000),
      max_events: Keyword.get(opts, :max_events, 1_000),
      max_duration_ms: Keyword.get(opts, :max_duration_ms, 60_000),
      started_at: System.monotonic_time()
    }
  end

  # Random rather than a VM counter so names stay unique across restarts
  # (log/telemetry correlation), without adding a UUID dependency — the
  # headless core promises hosts exactly two runtime deps (§7).
  defp generate_name, do: "wiretap-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
end
