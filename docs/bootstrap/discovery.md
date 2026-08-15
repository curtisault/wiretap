# Bootstrap (v0.0) — Discovery

> Component doc set for roadmap release **v0.0 — Bootstrap and de-risking**
> ([roadmap.md](../roadmap.md)). Companions: [implementation.md](implementation.md),
> [code-review.md](code-review.md).

**Scope:** project skeleton (§9 of [architecture.md](../architecture.md)), full tooling
baseline (discovery §C), CI, dev harness, and the three gating spikes.

## Questions to answer

Seeded from the main [discovery doc](../discovery.md); add component-specific ones below.

- [x] **A1** — registry-shape matrix spike: phoenix_pubsub 2.0/2.1/2.2 × `:group_by` × partitions
- [x] **A4** — snapshot poll-interval miss-rate + `Registry.select` cost at ~10k entries
- [x] **A6** — seq_trace singleton behavior under OTP trace sessions
- [ ] **C7** — does `dev/harness` get its own CI job or compile-check only?
- [ ] **C8** — ex_check vs hand-rolled `mix check` alias (recommendation: ex_check)
- [ ] Harness design: which demo LiveViews / broadcasters give the richest Roll Call content?

## Decision log

| Date | ID | Decision |
|---|---|---|
| 2026-08-14 | A6 | **Spike passed: 12/12 on OTP 29** ([spikes/a6_seq_trace.exs](spikes/a6_seq_trace.exs)). Confirmed: the seq_trace system tracer is **still a per-node singleton** in the trace-session world (`:trace` exposes no seq_trace scoping; single slot, last-set-wins), so v0.4's arbitration/serialization design is required, and `get_system_tracer/0` cleanly detects a foreign tracer (returns `false` when unset; clear with `set_system_tracer(false)`, not `:undefined`). A stamped token propagates through `Phoenix.PubSub.broadcast/3` to **every subscriber** with per-hop timestamps and stamping-pid attribution; unstamped broadcasts generate zero events; seq_trace and a `:trace.session_create` session observe the same process simultaneously without interference. |
| 2026-08-14 | A4 | **Spike run** ([spikes/a4_poll_missrate.exs](spikes/a4_poll_missrate.exs)). Select+group at 10k subscriptions / 2k topics: **~1.8ms avg** — even 100ms polling costs ~2% of one core, so poll cost is a non-issue. Miss rate (50 churners, jittered holds): 1s polling sees everything held ≥2s but misses **54%** of ~500ms holds and **93%** of ~100ms holds; 250ms polling captures ~500ms holds fully but misses 60% of ~100ms; 100ms polling still misses 7% of ~100ms holds. Conclusion: polling can never be honest about sub-interval churn (L2 stays the real fix per A2), **default 1s, auto-tighten to 250ms while a Timeline/Roll Call panel is focused**, honesty label required. |
| 2026-08-14 | A1 | **Spike passed: 84/84 checks.** phoenix_pubsub 2.0.0 / 2.1.3 / 2.2.0 × 7 start configs (defaults, `pool_size` 1/4, `registry_size: 8`, `group_by` `:pid`/`:key`, combined). The `Registry.select` topic→pid snapshot, broadcast fan-out through the same table, unsubscribe removal, and death cleanup (~50ms async) behave identically everywhere. Caveat: unknown start options are silently ignored, so `group_by` cells on 2.0/2.1 prove option-tolerance, not layout parity — the startup shape-probe (main discovery A1) stays in the design. Keep the `~> 2.1` pin. Script: [spikes/a1_registry_shape.exs](spikes/a1_registry_shape.exs) |
