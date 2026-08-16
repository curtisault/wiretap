# Tracer (v0.3) — Code Review

> Review record for the v0.3 release. Filled in during review, before merge.
> This is the highest-risk component — review against §8 line by line.

## Checklist

- [ ] Trace sessions only (§8.3): zero uses of legacy `:dbg` / global `:erlang.trace/3`
- [ ] Coexistence proven: test running alongside LiveDebugger and recon without collision
- [ ] Every budget bound (events, rate, wall clock) has a test that trips it and observes auto-detach
- [ ] Teardown removes all trace patterns and monitors on stop, expiry, AND crash (kill the manager mid-session in a test)
- [ ] No trace messages ever land in an application mailbox; receiver drop policy has a visible counter
- [ ] Match specs verified to filter at the trace layer (uninteresting calls generate no trace messages)
- [ ] `left_by_death` correctly distinguished in tests (kill vs unsubscribe)
- [ ] Refusal path when OTP < 27 or session creation fails is loud and actionable
- [ ] `mix check` green; coverage threshold met

## Findings

| # | Severity | File | Finding | Resolution |
|---|---|---|---|---|

## Sign-off

- Reviewed by: _
- Date: _
