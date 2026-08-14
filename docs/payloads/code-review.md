# Payloads (v0.4) — Code Review

> Review record for the v0.4 release. Filled in during review, before merge.

## Checklist

- [ ] Receive tracing attaches to explicitly selected pids only — never groups, never `:all`
- [ ] Payload storage honors the capture knob; default stores truncated previews only (§8.6)
- [ ] seq_trace: zero footprint verified when no token set; foreign system tracer detected → loud refusal (§8.3)
- [ ] Concurrent Broadcast Trace requests serialize; second user gets a clear "in use" state
- [ ] `:sys` hooks removed on session stop, expiry, AND crash; non-OTP processes refused gracefully
- [ ] Sensitive-data posture re-checked: previews in UI, file sink, and Inspector state views
- [ ] Cross-process fan-out tree correct in harness test with known topology (N subscribers, M no-match)
- [ ] `mix check` green; coverage threshold met

## Findings

| # | Severity | File | Finding | Resolution |
|---|---|---|---|---|

## Sign-off

- Reviewed by: _
- Date: _
