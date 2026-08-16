# Core (v0.1) — Implementation Companion

> Working notes while implementing roadmap v0.1. Discovery decisions live in
> [discovery.md](discovery.md).

## Checklist (mirrors roadmap v0.1)

- [x] `Wiretap.Snapshot`: select, diff, pid labeling, shape-probe with loud degradation
      *(probe reports; the loud wiring — log + telemetry + UI state — lands with SessionManager)*
- [x] `Wiretap.Session` / `SessionManager`: lifecycle, budgets, guaranteed teardown
- [x] `Wiretap.Collector`: ETS ring buffer, `%Wiretap.Event{}` normalization
- [x] `Wiretap.PubSub` own instance for UI nudges *(instance in tree; nudge broadcasts land with the first UI consumer)*
- [x] Own telemetry events (session start/stop/expired, budget exhausted)
- [x] ExUnit assertion helpers (`Wiretap.Test.assert_subscribed/4`, `refute_subscribed/4`, `assert_no_subscribers/3`)
- [x] LiveDashboard Roll Call page
- [ ] Origin-project dogfood via path dep (gates publish)
- [ ] Publish v0.1 to hex; repo public

## Design notes

_(fill in as implementation begins)_

## Progress log

| Date | Note |
|---|---|
| 2026-08-15 | Core design session: Event struct, A3 taxonomy, A1 probe, A9 labels, ring buffer — see discovery.md “Settled designs”. |
| 2026-08-15 | `Wiretap.Snapshot` shipped on `feat/aug26-core-snapshot` (commit ovo): take/diff/probe/label + `Wiretap` delegates. 13 tests incl. partitioned registry, death-vs-unsubscribe via diff, probe rejection of non-binary keys. `mix check` green. Label precedence adds process labels (`:proc_lib.set_label/1`) between registered name and `$initial_call` — cheap and idiomatic on OTP 27+; recorded as an A9 refinement. |

| 2026-08-15 | Session core shipped on `feat/aug26-core-sessions` (commit wyy): Event, Session, Collector, Snapshotter, SessionManager + `Wiretap.watch/stop/sessions/events`. 10 new tests: joined/left flow, silent baseline, both budget expiries, teardown-with-readable-events (ETS heir), crash marking, loud probe refusal. `mix check` green. Design addition: ring-buffer tables name SessionManager as heir so finished sessions stay inspectable. |

| 2026-08-15 | `Wiretap.Test` helpers shipped on `feat/aug26-core-test-helpers` (commit xqq): assert/refute_subscribed + assert_no_subscribers with opt-in `timeout:` retry (async death cleanup) and roll-call failure messages. 6 tests. `mix check` green, 29 tests total. |

| 2026-08-15 | Dashboard page shipped on `feat/aug26-core-dashboard-page` (commit lko): `Wiretap.DashboardPage` behind optional `phoenix_live_dashboard ~> 0.8` dep, rows via new headless `Snapshot.roll_call/1` (node-side over :erpc). Harness mounts it at /dashboard/wiretap with a router-level render test. All coding items of v0.1 are done — dogfood gate and hex publish remain. |

| 2026-08-15 | Demo reworked on `feat/aug26-core-demo-improvements` (commit pzk, PR #18) to an air-traffic-controller framing: `Harness.Tower` maintains a churning roster of flights (enter/transmit/land, 20–40s lifetimes) so **topics come and go** — exercising joined/left diffing and the stale-subscription-to-a-landed-flight case the static station demo couldn't show. Track many flights at once (toggle), "hand off all" = clean path, "walk off shift (leaky)" strands every tracked flight. Transmissions log flags leaked deliveries; registry-truth panel via `Wiretap.snapshot/1`. LiveView tests demo `Wiretap.Test` end-to-end against dynamic callsigns. |

## Deviations from plan

_(record anything done differently than discovery/roadmap decided, and why)_
