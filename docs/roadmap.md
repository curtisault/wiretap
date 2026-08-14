# Wiretap — Roadmap

> Adopted 2026-08-14 per discovery decision **A2** ([discovery.md](discovery.md)):
> telemetry bridge ships *before* the tracer, so the highest-risk component (tracing)
> lands into two releases of hardened session/collector scaffolding. Supersedes §10 of
> [architecture.md](architecture.md).

## Status at a glance

| Release | Contents | Status |
|---|---|---|
| **v0.0** | Project bootstrap, tooling baseline, dev harness, spikes | ⬜ not started |
| **v0.1** | Snapshot + diff engine, session manager, test helpers, LiveDashboard Roll Call page, own telemetry | ⬜ not started |
| **v0.2** | Telemetry bridge + probe macro, standalone endpoint (Roll Call + Timeline) | ⬜ not started |
| **v0.3** | Tracer (L2): caller attribution, death-vs-unsubscribe, budgets/auto-expiry | ⬜ not started |
| **v0.4** | Wiretap panel (3a), Broadcast Trace (3b), Process Inspector (4.2) | ⬜ not started |
| **v1.0** | Production profile, docs site, multi-node spike | ⬜ not started |

Statuses: ⬜ not started · 🟨 in progress · ✅ shipped

---

## v0.0 — Bootstrap and de-risking (pre-release)

Project skeleton per architecture §9, plus the spikes that gate design decisions
(discovery §E).

- [ ] `mix new wiretap --sup --module Wiretap`, git init, GitHub repo (private until v0.1)
- [ ] Tooling baseline (discovery §C): styler, credo `--strict` + `.credo.exs`,
      dialyxir (CI-cached PLT), sobelow + `.sobelow-conf`, mix_audit, ex_doc, doctor,
      excoveralls, ex_check as the single `mix check` entry point
- [ ] CI: lint job + test matrix (OTP 27/28/29 × Elixir 1.17–1.19),
      `--warnings-as-errors` on newest cell, `mix hex.build` dry-run,
      `deps.unlock --check-unused`, Dependabot
- [ ] Dev harness: `dev/harness` Phoenix app (path dep) with demo LiveViews that
      subscribe/unsubscribe on mount/clicks + timer-driven broadcaster; compile-checked in CI
- [ ] MIT license, CHANGELOG.md, hex package metadata in mix.exs
- [ ] **Spike A1** — registry-shape matrix (phoenix_pubsub 2.0/2.1/2.2 × `:group_by` × partitions)
- [ ] **Spike A4** — snapshot poll-interval miss-rate + `Registry.select` cost at ~10k entries
- [ ] **Spike A6** — seq_trace singleton behavior under OTP trace sessions (gates v0.4 design only; may slip)

## v0.1 — Headless core + Roll Call

- [ ] `Wiretap.Snapshot`: `Registry.select` snapshots, diffing, pid labeling
      (label policy per discovery A9), startup shape-probe with loud graceful
      degradation (A1)
- [ ] `Wiretap.Session` / `Wiretap.SessionManager`: lifecycle, budgets, guaranteed
      teardown (traps exits, never auto-resumes)
- [ ] `Wiretap.Collector`: ETS ring buffer, `%Wiretap.Event{}` normalization —
      designed for heterogeneous sources from day one
- [ ] `Wiretap.PubSub` own instance for UI nudges (never the host's)
- [ ] Wiretap's own telemetry events (A3): session start/stop/expired, budget exhausted
- [ ] ExUnit helpers: `Wiretap.Snapshot.topics/1` etc. as assertion primitives
- [ ] LiveDashboard Roll Call page (frozen scope per discovery B1: read-only teaser, permanent)
- [ ] Dogfood: SandDrive silo-set test replaces hand-rolled `Registry.keys/2` helper
      via path dep, lives with it a sprint (discovery C9) — **gates hex publish**
- [ ] Publish v0.1 to hex, flip repo public

## v0.2 — Timeline + standalone endpoint

- [ ] `Wiretap.TelemetryBridge` (§4.1): attach any telemetry event into the session timeline
- [ ] `Wiretap.Probe` macro (§4.4): compile-time gated, `:ok` outside dev
- [ ] Process monitors generalized (§4.3): UI never renders a dead pid as alive
- [ ] Timeline backend from snapshot diffs + telemetry + probes + `:DOWN`s
      (honesty label per A4 spike results: "approximate until L2 armed")
- [ ] `Wiretap.Endpoint` on :4008, dev-only, precompiled assets, dark mode (B8)
- [ ] Roll Call panel: prefix-collapsed topic tree, filter box, subscriber-count sort (B4)
- [ ] Timeline panel: follow mode, batched re-renders, dropped-events counter (B3)
- [ ] Empty states as first-class answers, esp. "nobody is listening to X" (B6)
- [ ] File log sink: opt-in option to append session events to `wiretap.log` at the
      project root, so users can review a full capture offline (and gitignore it).
      Off by default (idle = free); enabled per session or via
      `config :wiretap, log_file: "wiretap.log"`; one human-readable event per line
      with a session-start header; same truncated payload previews as the UI (§8.6);
      docs recommend adding `wiretap.log` to `.gitignore`
- [ ] Headless parity: documented public function per panel interaction (B9)

## v0.3 — Tracer (Layer 2)

- [ ] `Wiretap.Tracer`: OTP 27+ trace sessions only; refuse loudly if unavailable
- [ ] Match-spec-narrowed patterns: `Phoenix.PubSub.subscribe/3`, `unsubscribe/2`,
      `Registry.register/3`, `unregister/2`, user-added wrapper MFAs per session
- [ ] Receiver topology per A5 spike (per-session receiver, off-heap queue,
      drop-oldest + visible counter)
- [ ] recon-style budgets enforced: max events / rate / wall clock → auto-detach, `:expired` in UI
- [ ] `left_by_death` vs deliberate unsubscribe distinction
- [ ] Timeline upgraded in place: caller attribution, no polling gap
- [ ] Session/budget UX (B5): pre-arm attachment preview, live countdown + event meter, presets

## v0.4 — Payloads and fan-out (Layer 3)

- [ ] Wiretap panel (3a): per-pid `:receive` tracing on explicitly selected pids,
      payload capture knob per discovery B7 (off / 10KB / unlimited-dev-only)
- [ ] Broadcast Trace (3b): seq_trace token stamping, system-tracer ownership +
      request serialization + foreign-tracer detection (per A6 spike)
- [ ] Process Inspector (4.2): `:sys.install` hooks, auto-remove on session end,
      `$ancestors`/`$callers` chains in detail pane only (A9)
- [ ] Drill-down IA complete: Roll Call → Timeline → Inspector/Wiretap funnel (B2)

## v1.0 — Production-possible

- [ ] `config :wiretap, :profile, :production`: budgets ~10× tighter, 3a payload
      capture disabled, per-session confirmation required
- [ ] Docs site, README with panel table, `groups_for_modules` by layer
- [ ] Multi-node research spike: `:erpc` fan-in, Redis-adapter story (A7 findings)
- [ ] Coverage/doc gates at final thresholds (doctor, excoveralls minimums)
