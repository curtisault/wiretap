# Bootstrap (v0.0) — Implementation Companion

> Working notes while implementing roadmap v0.0. Keep this current as work proceeds;
> discovery decisions live in [discovery.md](discovery.md).

## Checklist (mirrors roadmap v0.0)

- [x] `mix new wiretap --sup --module Wiretap`, git init, GitHub repo
- [x] Tooling: styler, credo --strict, dialyxir, sobelow, mix_audit, ex_doc, doctor, excoveralls, ex_check
- [x] CI: lint job + test matrix (1.17/27, 1.18/27, 1.19/28, 1.20/29), hex.build dry-run, Dependabot
- [x] `dev/harness` Phoenix app with demo subscribers + broadcaster
- [x] MIT license, CHANGELOG.md, hex metadata
- [x] Spikes A1, A4, A6 executed and results recorded in discovery decision logs

## Design notes

_(fill in as implementation begins)_

## Progress log

| Date | Note |
|---|---|
| 2026-08-14 | Mix project scaffold existed from project init; added core deps (phoenix_pubsub, telemetry) and full tooling baseline on `chore/aug26-bootstrap-tooling`. `mix check` green: compiler, credo, dialyzer, doctor, ex_doc, ex_unit, formatter, mix_audit, sobelow, unused_deps. |
| 2026-08-14 | Spike A1 run via Mix.install matrix (`spikes/a1_registry_shape.exs`): 84/84 OK across phoenix_pubsub 2.0.0/2.1.3/2.2.0 × 7 configs. Result recorded in discovery decision logs. Old pubsub versions compile on Elixir 1.19 (Tracker type warnings only, harmless). |
| 2026-08-14 | Harness built on `feat/aug26-bootstrap-harness` (Phoenix 1.8.9): DemoLive with announcements subscribe on mount, station tune-in/tune-out, deliberately leaky walk-away; Broadcaster every 2s. Compiles with --warnings-as-errors, 5 generated tests pass. Demo vocabulary is the generic radio theme (stations/tuning/announcements). |
| 2026-08-14 | Spike A4 run (`spikes/a4_poll_missrate.exs`): select at 10k subs ~1.8ms; 1s poll misses 54% of 500ms holds / 93% of 100ms holds; 250ms captures 500ms holds fully. Poll defaults decided — see discovery log. |
| 2026-08-14 | Spike A6 run (`spikes/a6_seq_trace.exs`): 12/12 OK on OTP 29. Singleton confirmed (arbitration needed for v0.4), token propagates through broadcast with timestamps, foreign-tracer detection works, coexists with trace sessions. Gotcha: clear the system tracer with `set_system_tracer(false)`. v0.0 complete. |
| 2026-08-14 | CI on `chore/aug26-bootstrap-ci`: lint / test matrix (1.17/27 → 1.20/29, warnings-as-errors on newest) / dialyzer (cached PLT) / harness jobs + Dependabot. Package metadata, MIT LICENSE, CHANGELOG added; `mix hex.build` and full `mix check` verified locally. CI itself unexercised until first push. |

## Deviations from plan

_(record anything done differently than discovery/roadmap decided, and why)_
