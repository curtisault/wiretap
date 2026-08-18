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
    :log_file,
    interval_ms: 1_000,
    max_events: 1_000,
    max_duration_ms: 60_000,
    max_rate: 250,
    telemetry: [],
    trace: false,
    tap: [],
    payloads: 10_240,
    status: :running
  ]

  @type status :: :running | :stopped | :expired | :crashed

  @type t :: %__MODULE__{
          name: String.t(),
          pubsub: atom(),
          started_at: integer() | nil,
          log_file: String.t() | nil,
          interval_ms: pos_integer(),
          max_events: pos_integer(),
          max_duration_ms: pos_integer(),
          max_rate: pos_integer(),
          telemetry: [[atom()]],
          trace: false | trace_opts(),
          tap: [pid()],
          payloads: :off | pos_integer() | :unlimited,
          status: status()
        }

  @typedoc "Normalized layer-2 tracing options."
  @type trace_opts :: %{prefixes: [String.t()], mfas: [mfa()]}

  @doc """
  Builds a session for `pubsub`.

  Options: `:name` (defaults to a generated `"wiretap-<random hex>"`, unique
  across VM restarts), `:interval_ms` (default 1000 — see discovery A4),
  `:max_events` (default 1000), `:max_duration_ms` (default 60_000),
  `:telemetry` (host telemetry event names to bridge into the session),
  `:log_file` (append events to this file; defaults to
  `config :wiretap, :log_file`), `:max_rate` (events/sec before auto-expiry,
  default 250), `:trace` (`true` or `[prefixes: [...], mfas: [...]]` — arm
  layer-2 call tracing for exact events with caller attribution), `:tap`
  (explicitly selected pids whose received messages are captured as
  `:message` events — layer 3a), `:payloads` (`:off | bytes | :unlimited`,
  default 10_240 — preview size for tapped messages; §8.6 truncation).
  """
  @spec new(atom(), keyword()) :: t()
  def new(pubsub, opts \\ []) do
    %__MODULE__{
      name: Keyword.get_lazy(opts, :name, &generate_name/0),
      pubsub: pubsub,
      interval_ms: Keyword.get(opts, :interval_ms, 1_000),
      max_events: Keyword.get(opts, :max_events, 1_000),
      max_duration_ms: Keyword.get(opts, :max_duration_ms, 60_000),
      max_rate: Keyword.get(opts, :max_rate, 250),
      telemetry: Keyword.get(opts, :telemetry, []),
      trace: normalize_trace(Keyword.get(opts, :trace, false)),
      tap: Keyword.get(opts, :tap, []),
      payloads: Keyword.get(opts, :payloads, 10_240),
      log_file: Keyword.get(opts, :log_file, Application.get_env(:wiretap, :log_file)),
      started_at: System.monotonic_time()
    }
  end

  @doc "Milliseconds until the duration budget expires a running session (0 when finished)."
  @spec remaining_ms(t()) :: non_neg_integer()
  def remaining_ms(%__MODULE__{status: :running} = session) do
    elapsed =
      System.convert_time_unit(
        System.monotonic_time() - session.started_at,
        :native,
        :millisecond
      )

    max(session.max_duration_ms - elapsed, 0)
  end

  def remaining_ms(%__MODULE__{}), do: 0

  defp normalize_trace(false), do: false
  defp normalize_trace(true), do: %{prefixes: [], mfas: []}

  defp normalize_trace(opts) when is_list(opts) do
    %{prefixes: Keyword.get(opts, :prefixes, []), mfas: Keyword.get(opts, :mfas, [])}
  end

  # Random rather than a VM counter so names stay unique across restarts
  # (log/telemetry correlation), without adding a UUID dependency — the
  # headless core promises hosts exactly two runtime deps (§7).
  defp generate_name, do: "wiretap-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
end
