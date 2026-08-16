# Core (v0.1) — Discovery

> Component doc set for roadmap release **v0.1 — Headless core + Roll Call**
> ([roadmap.md](../roadmap.md)). Companions: [implementation.md](implementation.md),
> [code-review.md](code-review.md).

**Scope:** `Wiretap.Snapshot`, `Wiretap.Session`/`SessionManager`, `Wiretap.Collector`,
`Wiretap.PubSub`, own telemetry, ExUnit helpers, LiveDashboard Roll Call page,
origin-project dogfooding gate, first hex publish.

## Questions to answer

- [x] **A1** — version pin + startup shape-probe design (consumes v0.0 spike results)
- [x] **A3** — final telemetry event taxonomy (`[:wiretap, :session, ...]`) before SessionManager is written
- [x] **A4** — default poll interval + auto-tighten policy (consumes v0.0 spike results)
- [x] **A9** — pid label policy: registered name > LiveView module > initial_call
- [x] **B1** — LiveDashboard page frozen at read-only Roll Call teaser (recommendation: yes)
- [ ] **C9** — dogfood exit criteria: what must the origin project's test suite demonstrate before publish? *(needs origin-project context — stays open)*
- [x] `%Wiretap.Event{}` struct: field set that survives v0.2's heterogeneous sources unchanged
- [x] Ring buffer: size default, overwrite semantics, public-read access pattern

## Settled designs (2026-08-15)

### `%Wiretap.Event{}` — one struct for every source, forever

```elixir
%Wiretap.Event{
  seq: non_neg_integer(),   # Collector-assigned; authoritative order within a session
  at: integer(),            # System.system_time(:microsecond) — display only, never ordering
  kind: :joined | :left | :left_by_death | :probe | :telemetry | :message,
  source: :snapshot | :trace | :monitor | :probe | :telemetry | :receive_trace,
  topic: String.t() | nil,  # nil for telemetry events
  pid: pid() | nil,
  pid_label: String.t() | nil,
  payload_preview: String.t() | nil,  # truncated inspect only (§8.6)
  session: atom(),
  meta: map()               # kind-specific: caller MFA, measurements, probe label, exit reason…
}
```

The load-bearing choice is **`kind` and `source` as separate axes**. `kind` is semantic
(a `:joined` is a join), `source` says how we know (`:snapshot` = approximate,
`:trace` = exact). This is precisely what the A4 honesty label needs: the Timeline
renders one unified stream and badges snapshot-sourced events as approximate — and in
v0.3, trace-sourced `:joined` events slot into the same stream with zero migration.
`seq` exists because wall-clock timestamps can go backwards (NTP); insertion order in
the Collector is the one true order. Kinds reserved now for later releases: `:probe`,
`:telemetry` (v0.2), `:message` (v0.4).

### A3 — telemetry taxonomy (all emitted by Wiretap itself)

| Event | Measurements | Metadata |
|---|---|---|
| `[:wiretap, :session, :start]` | `%{system_time}` | `%{session, budgets, attachments}` |
| `[:wiretap, :session, :stop]` | `%{duration, events_captured}` | `%{session, reason: :manual \| :expired \| :crash}` |
| `[:wiretap, :budget, :exhausted]` | `%{events_captured}` | `%{session, bound: :max_events \| :max_duration \| :max_rate, limit}` |
| `[:wiretap, :collector, :dropped]` | `%{count}` | `%{session}` — reserved for v0.3 backpressure |
| `[:wiretap, :registry, :incompatible]` | `%{}` | `%{pubsub, reason}` — shape-probe failure |

Session start/stop follow the standard span convention (`duration` in native units)
so `:telemetry.span/3`-style consumers and dashboards work unmodified. Budget
exhaustion is deliberately its own event, not a stop-reason alone — it is the alarm
a host wants to page on ("someone left a tracer armed").

### A1 — shape-probe design

`Wiretap.Snapshot.probe/1` runs at session start, passive-first:

1. **Smoke:** `Registry.select/2` inside a rescue — an exit/error (wrong registry,
   not a registry) → `{:error, :no_registry}`.
2. **Shape validation:** every sampled row must be `{topic :: binary, pid}`; anything
   else → `{:error, :unrecognized_shape}` (spike A1 caveat: unknown start opts are
   silently ignored upstream, so validating output is the only guarantee).
3. An empty registry validates optimistically (nothing to disprove).

On failure: layer 1 is marked unavailable, one loud `Logger.warning`, one
`[:wiretap, :registry, :incompatible]` emission, and the UI's B6 empty state — never
silently wrong data. An *active* probe (momentary self-subscription to a unique
`"wiretap:probe:<ref>"` topic) is deferred; if ever added it is opt-in config and a
documented §8.4 carve-out.

### A9 — pid labels

Label = first hit of: registered name → `:"$initial_call"` module (with
`Phoenix.LiveView.Channel` rendered as the view module when it is cheaply readable
from the process dictionary, else "LiveView") → `inspect(pid)`. `$ancestors`/`$callers`
chains appear only in the v0.4 Process Inspector detail pane, never in tables.

### Ring buffer

One ETS table per session, owned by that session's Collector: `:protected` +
`read_concurrency: true` (owner-write, world-read — readers never call the
GenServer). Key = `seq`; capacity default **10_000**; overwrite-oldest via
`seq rem capacity` slotting. Readers use `Wiretap.Collector.events(session, opts)`
which reads ETS directly; the Collector process only ever writes.

## Decision log

| Date | ID | Decision |
|---|---|---|
| 2026-08-15 | — | `%Wiretap.Event{}` settled — kind/source as separate axes (honesty label mechanism), Collector-assigned `seq` as authoritative order. See “Settled designs” above |
| 2026-08-15 | A3 | Telemetry taxonomy fixed (5 events, span-convention session start/stop, budget exhaustion as its own alarm event). See “Settled designs” |
| 2026-08-15 | A1 | Shape-probe: passive-first (select smoke + row-shape validation), loud triple-signal failure (log + telemetry + UI state); active probe deferred/opt-in |
| 2026-08-15 | A4 | Poll defaults adopted from spike: 1s default, 250ms while a panel is focused, honesty badge on snapshot-sourced events |
| 2026-08-15 | A9 | Label = registered name → `$initial_call` (LiveView special-cased) → `inspect(pid)`; chains Inspector-only |
| 2026-08-15 | B1 | Confirmed: LiveDashboard page ships in v0.1 frozen at read-only Roll Call; permanent teaser, never grows features |
| 2026-08-15 | — | Ring buffer: per-session protected ETS, read_concurrency, 10k capacity, overwrite-oldest by `seq rem capacity` |
