# Payloads (v0.4) — Discovery

> Component doc set for roadmap release **v0.4 — Payloads and fan-out (Layer 3)**
> ([roadmap.md](../roadmap.md)). Companions: [implementation.md](implementation.md),
> [code-review.md](code-review.md).

**Scope:** Wiretap panel (3a per-pid receive tracing), Broadcast Trace (3b seq_trace),
Process Inspector (§4.2 `:sys` hooks), completed drill-down IA.

## Questions to answer

- [x] **A6** — consume v0.0 spike: seq_trace system-tracer singleton semantics under sessions; arbitration design
- [x] **B2** — drill-down IA final shape: Roll Call home + Timeline tab + contextual panes
- [x] **B7** — payload capture knob (off / 10KB / unlimited-dev-only) semantics and defaults
- [x] **A9** — ancestor/caller chains in Inspector detail pane: how deep, how rendered
- [x] seq_trace token scope: what else in the host uses seq_trace? Detection + refusal path
- [x] Fan-out tree rendering: causal order + per-hop timings; "matched no clause" detection mechanism
- [x] `:sys.install` on non-OTP-compliant processes: detection and graceful refusal
- [x] Receive-trace filtering: PubSub-shape heuristics vs topic-selected only

## Settled designs (2026-08-17, evidence: [spikes/p1_receive_sys_seq.exs](spikes/p1_receive_sys_seq.exs), 17/17 on OTP 29)

### Broadcast Trace (3b) — injected, not intercepted *(deviation from §3.3b/§6)*

A seq token can only be stamped **by the sending process**; wiretap cannot inject a
token into an arbitrary host process's organic broadcast. Architecture §6's
"arm → *next* broadcast on topic X" is therefore not implementable from outside.
v0.4 ships the honest version: `Wiretap.trace_broadcast(pubsub, topic, message,
opts)` — wiretap stamps and sends the broadcast itself from a dedicated process,
the SessionManager-arbitrated system tracer (one trace at a time node-wide;
`get_system_tracer() != false` → `{:error, :foreign_tracer}`) collects the tree, and
the call returns hops with serials and per-hop timestamps. **Multi-hop works**: the
token propagates through relays (subscriber re-broadcasts traced end-to-end), which
is the part no other tool has. Organic-broadcast stamping remains possible only
in-band (a probe-style `traced_broadcast` wrapper) — deferred.

Spike finding for tree assembly: **exit signals propagate the token** and surface as
`:send` events (a dying relay's `{:EXIT, _, _}` to its Registry link) — system
signals are classified out of the delivery tree. "Matched no clause" detection is
**demoted to research**: it requires correlating per-receiver handle_info call
traces; not v0.4.

### Wiretap panel (3a) — `tap:` on sessions

`Wiretap.watch(pubsub, tap: [pid, ...])` (combinable with `trace:`): the Tracer arms
`:trace.process(session, pid, true, [:receive])` per explicitly selected pid — never
groups, never `:all`. Events: `kind: :message, source: :receive_trace`,
`topic: nil`, payload preview per the B7 knob. **Per-topic filtering of received
messages is impossible** — PubSub delivers raw payloads carrying no topic — so the
design is honest capture-all per tapped pid, budget-protected (spike confirmed the
full payload arrives in the trace message, and only for tapped pids).
`:trace.recv/3` match specs DO filter on message *shape* in the VM (spike-proven) —
kept in the toolbox for a future user-supplied-pattern option, not default.

### B7 — payload knob

`payloads: :off | bytes | :unlimited`, default **10_240** for sessions with `tap:`.
Implemented as inspect truncation budgets derived from the byte size; `:off` stores
kind-only `:message` events; `:unlimited` is dev-only (the v1.0 production profile
refuses it). Previews everywhere else (§8.6) are unchanged.

### Process Inspector (4.2) + A9 chains

Detection **before** any `:sys` call: pdict `$initial_call` presence identifies
OTP-compliant processes (spike: a blind `:sys.install` on a raw pid can only time
out — never probe blind). The Inspector opens from a Roll Call topic-inspector row:
`:sys.get_state` preview (truncated per §8.6), A9 `$ancestors`/`$callers` chains
rendered as full-depth breadcrumbs (detail pane only), and a live message feed via a
temporary debug fun sending straight to the inspecting LiveView — capped at 50,
removed on close and on inspector death (`:sys.remove` verified; note a single
message fires several system events).

### B2 — the drill-down funnel, realized

Roll Call topic inspector rows gain two actions: **tap messages** (adds the pid to a
session's `tap:` list and lands on its Timeline) and **inspect process** (the `:sys`
Inspector). The funnel is: Roll Call → topic → subscriber → tap / inspect →
Timeline. No new top-level panels.

## Decision log

| Date | ID | Decision |
|---|---|---|
| 2026-08-17 | — | **Spike P1: 17/17.** Per-pid receive tracing via sessions with full payloads; `:trace.recv/3` shape filtering works in the VM; `:sys.install`/`remove`/get_state verified with `$initial_call` pre-detection (blind install only times out); relay chains carry the token end-to-end; **exit signals carry the token too** — classify out of the tree |
| 2026-08-17 | A6 | Broadcast Trace is **injected, not intercepted** — external arming of organic broadcasts is impossible (deviation from §3.3b/§6 recorded); manager-arbitrated singleton, foreign-tracer refusal, injected `trace_broadcast/4` returns the multi-hop causal tree |
| 2026-08-17 | B7 | `payloads: :off \| bytes \| :unlimited`, default 10KB with `tap:`; :unlimited refused by the future production profile |
| 2026-08-17 | B2/A9 | Funnel via topic-inspector row actions (tap / inspect); chains full-depth, Inspector-only; "matched no clause" demoted to research |
| 2026-08-19 | — | **Broadcast Trace crash finding** (field-tested in the demo): the injected test broadcast is a real message — a subscriber with no catch-all `handle_info` (typical LiveView) crashes on it, and the seq token rides the entire crash cascade (code_server loads of error formatters, logger casts, io plumbing, spawn protocol) into the tree. Fix: infrastructure hops classified out (registered system names + message shapes + spawn-taint propagation, surfaced as a count), and the crash diagnosed honestly from the abnormal token-carrying exit signal (`recipient_crashed?`). Modal + docs now warn. **v1.0 note:** the production profile should confirm-gate `trace_broadcast` — it is the one thing wiretap does that can crash a host process |
| 2026-08-18 | — | **Vitals addendum** (post-close): periodic process vitals ship as an Inspector-pane sample riding the existing 1s refresh — open pane = sampled, closed = free — never a standing emitter process (contract §8.1). `SysInspector.vitals/1` is the headless twin; it needs no `:sys`, so refused raw pids get vitals too |
