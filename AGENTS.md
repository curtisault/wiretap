# Wiretap — Agent Guide

Wiretap is a planned open-source Elixir library for live `Phoenix.PubSub` introspection:
who is subscribed to which topics (Roll Call), subscription lifecycle as events
(Timeline), actual message payloads (Wiretap panel), and broadcast fan-out trees
(Broadcast Trace). `Phoenix.PubSub` emits no telemetry, so this works via Registry
introspection and OTP 27+ trace sessions instead.

**Current state:** freshly bootstrapped `mix new wiretap --sup` scaffold. The design
lives in `docs/`; almost none of it is implemented yet. Read the docs before writing
code.

## Document map (read in this order)

| File | Role |
|---|---|
| `docs/architecture.md` | The design: three attachment layers, event pipeline, UI strategy, packaging, safety contract (§8) |
| `docs/discovery.md` | Open questions (IDs like A1, B2, C3), verified facts (§0), **decision log (§D)**, spike queue (§E) |
| `docs/roadmap.md` | Source of truth for sequencing — per-release checklists with status. Supersedes architecture.md §10 |

## Workflow conventions

- **Roadmap tracking:** when you complete a roadmap item, tick its checkbox in
  `docs/roadmap.md` and update the release's status emoji in the status table.
- **Decisions:** when an open question from `docs/discovery.md` gets answered, record
  it in the decision log (§D) with date and question ID. Don't relitigate logged
  decisions.
- **Sequencing:** follow the roadmap order. Notably, the telemetry bridge ships in
  v0.2 *before* the tracer (v0.3) — decision A2. Don't build tracing early.

## Commands

```bash
mix test            # run tests
mix format          # format (config: .formatter.exs)
mix compile --warnings-as-errors
```

Planned but **not yet installed** (roadmap v0.0): styler, credo `--strict`, dialyxir,
sobelow, mix_audit, ex_doc, doctor, excoveralls, with `ex_check` (`mix check`) as the
single entry point. Once added, run `mix check` before considering work done.

## Design contracts (non-negotiable, from architecture.md §8)

1. **Idle = free.** No pollers, trace patterns, or handlers unless a session is live.
2. **Everything attached is budgeted** (events, rate, wall clock) and **everything is
   torn down** on session end/expiry/crash. Sessions never auto-resume.
3. **OTP 27+ trace sessions only** — never legacy `:dbg`/`:erlang.trace` globals.
4. **Read-only toward the host app.** Never subscribe to host topics, send to host
   processes, or mutate host ETS. Wiretap has its own `Wiretap.PubSub` for UI updates.
5. **Payloads are truncated previews** — never store or render full terms.

## Version floors

- **OTP 27** (trace sessions gate this) / **Elixir 1.17** — the generated `mix.exs`
  currently says `elixir: "~> 1.19"`, which needs loosening to `~> 1.17` before
  publish (roadmap v0.0).
- CI matrix (once set up): OTP 27/28/29 × Elixir 1.17–1.19.

## Layout (target, from architecture.md §7)

```
lib/wiretap/
  session.ex, session_manager.ex   # lifecycle, budgets, teardown guarantees
  snapshot.ex                      # L1: Registry.select, diffing, pid labeling
  tracer.ex                        # L2/3a: trace sessions, match specs
  seq_tracer.ex                    # 3b: broadcast fan-out
  collector.ex                     # ETS ring buffer, %Wiretap.Event{} normalization
  probe.ex, telemetry_bridge.ex, sys_inspector.ex
  ui/                              # optional: endpoint on :4008, LiveView panels
dev/harness/                       # throwaway Phoenix app, path-deps wiretap (v0.0)
```

UI deps (`phoenix_live_view`, `phoenix`, `bandit`) are `optional: true`; every UI
module is gated with `Code.ensure_loaded?(Phoenix.LiveView)`. The headless core must
stay fully usable from iex and ExUnit.
