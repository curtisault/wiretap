defmodule Wiretap.Event do
  @moduledoc """
  One normalized event, regardless of where it came from.

  `kind` and `source` are deliberately separate axes (see the settled designs
  in `docs/core/discovery.md`): `kind` is the semantic fact (a `:joined` is a
  join), `source` is how Wiretap learned it — `:snapshot`-sourced events are
  approximate (polling can miss sub-interval churn), `:trace`-sourced events
  are exact. UIs badge honesty from `source` while rendering one stream.

  `seq` is assigned by the session's Collector at capture time and is the
  authoritative order within a session; `at` is wall-clock and for display
  only (wall clocks can go backwards, insertion order cannot).
  """

  @enforce_keys [:seq, :at, :kind, :source, :session]
  defstruct [
    :seq,
    :at,
    :kind,
    :source,
    :topic,
    :pid,
    :pid_label,
    :payload_preview,
    :session,
    meta: %{}
  ]

  @typedoc """
  Semantic fact. `:call` is a traced user-added wrapper MFA hit (v0.3);
  `:message` arrives in v0.4.
  """
  @type kind :: :joined | :left | :left_by_death | :probe | :telemetry | :call | :message

  @typedoc "How Wiretap learned it — the honesty axis."
  @type source :: :snapshot | :trace | :monitor | :probe | :telemetry | :receive_trace

  @type t :: %__MODULE__{
          seq: non_neg_integer(),
          at: integer(),
          kind: kind(),
          source: source(),
          topic: String.t() | nil,
          pid: pid() | nil,
          pid_label: String.t() | nil,
          payload_preview: String.t() | nil,
          session: String.t(),
          meta: map()
        }
end
