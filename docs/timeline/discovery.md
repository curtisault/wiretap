# Timeline (v0.2) — Discovery

> Component doc set for roadmap release **v0.2 — Timeline + standalone endpoint**
> ([roadmap.md](../roadmap.md)). Companions: [implementation.md](implementation.md),
> [code-review.md](code-review.md).

**Scope:** telemetry bridge, probe macro, generalized monitors, Timeline backend
(diffs + telemetry + probes + `:DOWN`s), `Wiretap.Endpoint` on :4008, Roll Call and
Timeline panels, empty states, file log sink (`wiretap.log`), headless parity.

## Questions to answer

- [x] **A4** — wording/placement of the "approximate until L2 armed" honesty label
- [x] **B3** — follow-mode, batched re-render cadence, dropped-events counter design
- [x] **B4** — prefix-collapse algorithm for the topic tree; default sort
- [x] **B6** — empty-state inventory: no subscribers, no sessions, budget exhausted, layer unavailable
- [x] **B8** — CSS approach (hand-rolled vs Tailwind-at-build), dark mode, identity color
- [x] **B9** — public function API per panel interaction (name them before building the panel)
- [x] File sink: line format spec, session-start header contents, append/rotate behavior
- [x] Probe macro: config gate mechanics (`config :wiretap, probes: true`), compile-away verification

## Settled designs (2026-08-15)

### Telemetry bridge (§4.1)

Per-session opt-in: `Wiretap.watch(pubsub, telemetry: [[:my_app, :repo, :query], …])`.
The bridge attaches **one handler per session** (`:telemetry.attach_many/4`, handler id
`"wiretap-<session>"`), which pushes to the session's Collector: `kind: :telemetry`,
`source: :telemetry`, `topic: nil`, `payload_preview` = truncated inspect of
measurements (§8.6), `meta: %{event: name, metadata_preview: …}`. Telemetry events
count toward `max_events` like everything else. Teardown detaches the handler
(SessionManager's teardown list grows a `:telemetry` entry). A raising handler is
auto-detached by telemetry itself — acceptable; it cannot hurt the host.

### Probe macro (§4.4)

Gate: `Application.compile_env(:wiretap, :probes, false)` read at **host** compile
time — explicit opt-in via `config :wiretap, probes: true` in the host's `dev.exs`,
rather than architecture.md's "dev default": implicit-by-Mix.env is magic that breaks
in releases and surprises umbrella apps. *(Deviation from §4.4 recorded.)* Enabled
expansion calls `Wiretap.Probe.__emit__/3`, which pushes `kind: :probe` to **every
running session** (via the session index; no sessions → cheap no-op). Disabled
expansion is literal `:ok` — verified by a test that macro-expands under both configs
and asserts on the AST.

### Monitors (§4.3) — death-vs-unsubscribe without the tracer

The Snapshotter monitors every pid it has emitted a `:joined` for. On `:DOWN` it
records `pid → {reason, at}`; at the next poll, a `:left` edge whose pid died renders
as `kind: :left_by_death, source: :monitor, meta: %{reason: reason}` instead of a
plain `:left` (source `:snapshot`). Pids that leave cleanly are demonitored. This
lands the leak-vs-crash distinction one release before the tracer.

### Endpoint + assets (B8)

`Wiretap.UI.Endpoint` on port **4008**, started only when `config :wiretap, ui: true`
(or `[port: n]`) **and** the optional UI deps are loaded — otherwise one loud log
line. Never touches host router/sessions/auth. **CSS is hand-rolled**, one static
file committed under `priv/static` — no Tailwind/esbuild/node anywhere in the library
build (contributor setup stays `mix deps.get`). Dark mode via
`prefers-color-scheme` plus a manual toggle. Identity: **phosphor green** accent
(oscilloscope/monitoring aesthetic) so Wiretap tabs are instantly distinguishable
from LiveDashboard (blue) and LiveDebugger (purple).

### Roll Call panel (B4)

One level of prefix grouping (not a recursive tree): split on `":"`, group topics
sharing a first segment when the group has ≥2 members, render `station:* (23 topics,
41 subscribers)` collapsed with expand; singletons stay flat. Filter box is a
contains-match applied before grouping. Default sort: groups and topics by subscriber
count, descending — anomalies float to the top. Headless equivalent:
`Wiretap.Snapshot.roll_call(pubsub, group: ":")`.

### Timeline panel (B3 + A4)

- **Follow mode** on by default; scrolling up auto-pauses (a "paused — N new" pill
  resumes it; `journalctl -f` ergonomics). One small JS hook; no other JS.
- **Batched renders:** Collector broadcasts a count nudge per push on
  `Wiretap.PubSub`; the LiveView coalesces nudges and re-reads ETS at most every
  **250ms**. Payloads never ride the nudges (§5).
- **Overwrite disclosure:** header shows "showing last 10_000 of N" from
  `Collector.count/1` vs retained size once the ring wraps.
- **Honesty label (A4):** every snapshot-sourced row carries an "≈" badge; the panel
  header shows a resolution chip — *"resolution ≈ {interval} (snapshot polling); exact
  timing and caller attribution arrive with trace sessions (v0.3)"*. Trace-sourced
  events (v0.3) will render badge-free in the same stream — that is what the
  kind/source axes were for.

### Empty states (B6) — the inventory

| Where | State | Copy + action |
|---|---|---|
| Roll Call | registry empty | "Nobody is subscribed to anything on {pubsub}." + verify-pubsub hint |
| Roll Call | filter matches nothing | "Nobody is listening to '{q}'." + "watch for future subscribers" CTA (arms a session) |
| Timeline | no session | "No capture session." + start-session CTA |
| Timeline | session expired | "Session expired ({bound} budget). Events below are retained." + restart CTA |
| Any panel | shape-probe failed | banner: "Layer 1 unavailable for {pubsub}: {reason}" + docs link |
| Sessions list | none ever | start-session CTA |

No panel ever renders a bare empty table.

### File sink (roadmap v0.2 item)

Opt-in per session (`Wiretap.watch(pubsub, log_file: "wiretap.log")`) or globally
(`config :wiretap, log_file: …` — applies to every session). The Collector owns the
file handle: opened at session start (open failure → `{:error, {:log_file, reason}}`
from `watch/2`, loudly), **append-only**, closed at teardown. No rotation — budgets
bound each session's volume and the file is a dev artifact (docs say gitignore it).
Format: session-start header comment then one event per line, grep-able:

```
# wiretap session wiretap-9f3a2c01 pubsub=Harness.PubSub budgets=1000ev/60s started 2026-08-15T21:04:11Z
2026-08-15T21:04:12.123456Z wiretap-9f3a2c01 joined station:jazz #PID<0.532.0> "LiveView" source=snapshot
2026-08-15T21:04:14.201133Z wiretap-9f3a2c01 left_by_death station:jazz #PID<0.532.0> "LiveView" source=monitor reason=:shutdown
```

Payload previews only, same truncation as ETS (§8.6).

### Headless parity (B9) — the function behind every interaction

| Panel interaction | Public API |
|---|---|
| Roll Call table / tree | `Wiretap.snapshot/1`, `Wiretap.Snapshot.roll_call/2` |
| Timeline stream | `Wiretap.events/1` (+ `Wiretap.watch/2`, `stop/1`, `sessions/0`) |
| Telemetry rows | `watch/2` `:telemetry` option |
| Probe rows | `Wiretap.Probe.tap/2` |
| File log | `watch/2` `:log_file` option |
| Start/stop/status controls | `watch/2`, `stop/1`, `sessions/0` |

Rule: any new panel interaction lands together with its documented function, or not
at all.

## Decision log

| Date | ID | Decision |
|---|---|---|
| 2026-08-15 | A4 | Honesty label settled: "≈" badge per snapshot-sourced row + panel resolution chip; trace events will join the same stream badge-free. See “Settled designs” |
| 2026-08-15 | B3 | Follow-mode with auto-pause; 250ms coalesced re-renders off count nudges; overwrite disclosure from `Collector.count/1` |
| 2026-08-15 | B4 | Single-level prefix grouping on `":"` (≥2 members), contains filter before grouping, subscriber-count-desc sort; headless `roll_call/2` with `group:` opt |
| 2026-08-15 | B6 | Empty-state inventory fixed (6 states, each with copy + action); bare empty tables banned |
| 2026-08-15 | B8 | Hand-rolled static CSS in priv/static (no node in library build), dark mode via prefers-color-scheme + toggle, phosphor-green identity accent, endpoint opt-in on :4008 |
| 2026-08-15 | B9 | Parity rule adopted: every panel interaction ships with its documented public function (table above) |
| 2026-08-15 | — | Telemetry bridge: per-session attach_many, events count toward budget, teardown detaches. Probe gate: explicit `compile_env(:wiretap, :probes, false)` — **deviation from §4.4's dev-default**, recorded. Monitors fold into Snapshotter (left_by_death in v0.2). File sink: append-only, header + one grep-able line per event, open-failure refuses the session option loudly |
