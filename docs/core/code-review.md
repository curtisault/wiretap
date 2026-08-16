# Core (v0.1) — Code Review

> Review record for the v0.1 release. Filled in during review, before merge.

## Checklist

- [ ] Safety contract §8.1: installing the dep changes nothing at runtime; no pollers without a live session
- [ ] Safety contract §8.2: session teardown verified for stop, expiry, AND crash paths (terminate/2 tested)
- [ ] Safety contract §8.4: read-only toward host — no host-topic subscriptions, no host ETS writes
- [ ] Shape-probe failure degrades loudly, never returns silently wrong data
- [ ] Snapshot correct with `registry_size > 1` and both `:group_by` values
- [ ] Public API fully @spec'd and @doc'd (doctor green); doctests where examples exist
- [ ] ExUnit helpers usable without starting the UI or a session manager where possible
- [ ] `mix check` green; coverage threshold met

## Findings

| # | Severity | File | Finding | Resolution |
|---|---|---|---|---|

## Sign-off

- Reviewed by: _
- Date: _
