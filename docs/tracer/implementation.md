# Tracer (v0.3) — Implementation Companion

> Working notes while implementing roadmap v0.3. Discovery decisions live in
> [discovery.md](discovery.md).

## Checklist (mirrors roadmap v0.3)

- [x] `Wiretap.Tracer` on OTP trace sessions; loud refusal when unavailable
- [x] Match-spec-narrowed patterns: PubSub subscribe/unsubscribe (both arities), per-session wrapper MFAs
      *(Registry register/unregister dropped — see deviations)*
- [x] Receiver per A5 decision (off-heap queue, watermark drop + dropped telemetry)
- [x] Budgets enforced: events / rate / wall clock → auto-detach, `:expired` in UI
- [x] `left_by_death` vs deliberate unsubscribe (tracer-owned monitors: no poll-gap misses)
- [x] Timeline upgraded in place: caller attribution, no polling gap
- [x] Session/budget UX (B5): pre-arm preview, countdown, event meter

## Design notes

_(fill in as implementation begins)_

## Progress log

| Date | Note |
|---|---|
| 2026-08-16 | Discovery session run as spikes-plus-decisions: T1 (12/12 on OTP 29) settled receiver topology, both-arities/:global arming (the default-args-wrapper catch), {:caller} attribution, binary_part prefix guards, session coexistence, max_rate budget. All eight questions closed — see discovery.md "Settled designs". |

| 2026-08-16 | Tracer shipped on `feat/aug26-tracer-core` (commit pvu): trace sessions, VM-level prefix filtering, {:caller} attribution, watermark drop mode, max_rate budget (Collector-enforced across all sources), B5 arm form with pre-arm preview/countdown/meters. 54 tests green ×5 runs; full `mix check` green. |

## Deviations from plan

- **Registry.register/unregister tracing dropped from v0.3.** Tail-call optimization
  erases the caller frame (`Phoenix.PubSub.unsubscribe/2` is a tail delegate to
  `Registry.unregister/2`), so caller-based dedup against the PubSub events is
  unsound — it produced duplicate `:left` rows in tests. Direct-Registry users are a
  rare audience; revisit alongside v0.4. `{:caller}` reporting the nearest non-tail
  frame also means wrapper attribution skips tail-delegating wrappers to their own
  caller — documented as the truer answer.
- **Traced sessions run the Tracer *instead of* the Snapshotter** (architecture §2
  implied both). Polling would only duplicate exact events approximately, and
  poll-based monitors can miss a subscriber that joins and dies within one interval —
  the tracer seeds a baseline snapshot at init and owns the monitors, closing that
  race entirely.
- **Trace-session name is a constant atom** (`:wiretap`): session names are debugging
  labels with no uniqueness requirement, and per-session interpolated atoms were an
  atom leak (caught by sobelow's DOS.BinToAtom).
