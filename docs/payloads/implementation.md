# Payloads (v0.4) — Implementation Companion

> Working notes while implementing roadmap v0.4. Discovery decisions live in
> [discovery.md](discovery.md).

## Checklist (mirrors roadmap v0.4)

- [x] Wiretap panel (3a): per-pid `:receive` tracing, explicitly selected pids only
- [x] Payload capture knob per B7 (off / 10KB / unlimited-dev-only)
- [x] Broadcast Trace (3b): token stamping, system-tracer ownership, request serialization, foreign-tracer detection
- [x] Process Inspector (4.2): `:sys.install` hooks, auto-remove on session end
- [x] Ancestor/caller chains in detail pane only (A9)
- [x] Drill-down IA complete (B2)

## Design notes

_(fill in as implementation begins)_

## Progress log

| Date | Note |
|---|---|
| 2026-08-19 | Broadcast Trace crash-noise fix on `fix/aug26-trace-crash-noise`: trees no longer dump a dying recipient's autopsy — system hops classified out with a count, `recipient_crashed?` from the abnormal exit signal, warnings in the modal and docs. Demo fix on the harness stack: `DemoLive` gains the catch-all `handle_info` every shared-topic subscriber needs. Also: Timeline display filter (`?q=` deep-linkable) + per-pid tap honesty note (`feat/aug26-timeline-filter`). |
| 2026-08-18 | Vitals addendum shipped on `feat/aug26-inspector-vitals`: `SysInspector.vitals/1` (memory/heap in bytes, queue, reductions, status — plain `Process.info`, works on raw pids) rendered in the Inspector pane and re-sampled on the existing 1s refresh with a reductions/s delta; no emitter process, nothing runs with the pane closed. Companion harness branch `feat/aug26-harness-telemetry`: tower telemetry (`[:harness, :tower, :entered\|:landed\|:transmission]`) to feed the v0.2 bridge demo, plus `Harness.TelemetryDebug.on/1` console tap and `.iex.exs` wiring. |
| 2026-08-18 | Docs-currency close-out: both `/docs` flow diagrams gained the layer-3 line (tap / trace_broadcast / peek), both iex samples gained `Wiretap.peek/1`; headless-twin tables were already current from the feature branches. v0.4 marked ✅ shipped in the roadmap. |
| 2026-08-18 | Process Inspector shipped on `feat/aug26-payloads-inspector`: `Wiretap.SysInspector` (`peek/1` behind `Wiretap.peek/1`, `watch_messages/3`, `stop_watching/2`) — pdict `$initial_call` detection before any `:sys` call (P1: blind install only times out), truncated `get_state` preview, full-depth `$ancestors`/`$callers` breadcrumbs (A9), live feed via a self-removing `:sys` debug fun (cap 50, dead-receiver cleanup, eager removal on close/terminate). Roll Call topic inspector gains the "inspect" row action, completing the B2 funnel. Both docs pages updated. `:sys.install` gotcha: the FuncSpec is `{FuncId, Func, State}` — the map form doesn't exist. 82 wiretap + 14 harness tests, full `mix check` green. |
| 2026-08-18 | Broadcast Trace shipped on `feat/aug26-payloads-broadcast-trace` (commit mwt, PR #47): `Wiretap.trace_broadcast/4` via the SeqTracer arbiter — injected stamped broadcasts, multi-hop trees with µs deltas, exit-signal classification, foreign-tracer refusal, honest empty answer. Topic inspector gains send+trace. Ports moved earlier on the stack (harness :5555, UI :5556, PR #46). 71 wiretap tests green. |
| 2026-08-18 | Tap shipped on `feat/aug26-payloads-tap`: `watch/2` gains `tap:`/`payloads:`; tap-only sessions run Snapshotter+Tracer (receive-only), trace+tap combine; :message events with knob-sized previews; "tap messages" button in the Roll Call topic inspector lands on the session's Timeline; both docs pages updated. Dialyzer lesson: validate raw opts, not typespec'd structs (rejection clauses unreachable otherwise). 65 wiretap + 14 harness tests green. |

## Deviations from plan

_(record anything done differently than discovery/roadmap decided, and why)_
