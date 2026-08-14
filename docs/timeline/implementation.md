# Timeline (v0.2) — Implementation Companion

> Working notes while implementing roadmap v0.2. Discovery decisions live in
> [discovery.md](discovery.md).

## Checklist (mirrors roadmap v0.2)

- [x] `Wiretap.TelemetryBridge` (§4.1)
- [x] `Wiretap.Probe` macro (§4.4), `:ok` unless the host opts in
- [x] Generalized process monitors (§4.3)
- [x] Timeline backend from diffs + telemetry + probes + `:DOWN`s, honesty label per A4
- [x] `Wiretap.Endpoint` on :4008, dev-only, precompiled assets, dark mode
- [x] Roll Call panel: topic tree, filter, subscriber-count sort
- [x] Timeline panel: follow mode, batched re-renders, dropped counter (ring-overwrite disclosure)
- [x] Empty states (B6)
- [x] File log sink: opt-in `wiretap.log`, §8.6-compliant previews, gitignore guidance
- [x] Headless parity functions documented per panel

## Design notes

_(fill in as implementation begins)_

## Progress log

| Date | Note |
|---|---|
| 2026-08-15 | v0.2 design session: all eight discovery questions settled (telemetry bridge, probe gate, monitors-in-Snapshotter, endpoint/assets, Roll Call grouping, Timeline follow/batching/honesty, empty states, file sink, B9 parity table) — see discovery.md “Settled designs”. |
| 2026-08-15 | Monitors shipped on `feat/aug26-timeline-monitors` (commit xmu): Snapshotter monitors all snapshot pids, deaths render as `left_by_death` + exit reason, death records survive staggered registry cleanup. 34 wiretap tests green; harness unaffected. Note: test subscribers that "left" by dying are now correctly `left_by_death` — the clean-leave test uses a real unsubscribe. |

| 2026-08-15 | Event sources shipped on `feat/aug26-timeline-sources` (commits yyr, wmt): telemetry bridge (validated `:telemetry` option, attach/detach in session lifecycle), probe macro (compile_env(__CALLER__) gate, AST-verified compile-away), file sink (append-only, header + grep-able lines, loud open-failure refusal). Sobelow false-positive on the sink's File.open skipped via annotation; .sobelow-conf/.check.exs/CI aligned on --config. 40 wiretap tests green. |

| 2026-08-15 | Standalone UI shipped on `feat/aug26-timeline-endpoint` (commit kll): endpoint on :4008 behind `config :wiretap, ui:` + optional-dep detection; hand-rolled CSS/JS, phoenix/live_view JS served from installed deps (zero build step); Roll Call (grouping via new `Snapshot.roll_call/2`/`group/2`) and Timeline (nudge-coalesced, follow mode, honesty badges, overwrite disclosure, empty-state inventory). Boot-verified over HTTP on :4008. All v0.2 checklist items complete — release pending review/merge. |

## Deviations from plan

_(record anything done differently than discovery/roadmap decided, and why)_
