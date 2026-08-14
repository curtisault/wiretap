# Timeline (v0.2) — Code Review

> Review record for the v0.2 release. Filled in during review, before merge.

## Checklist

- [ ] Endpoint is dev-only and never touches host router/sessions/auth; assets precompiled (no host esbuild coupling)
- [ ] UI updates ride `Wiretap.PubSub`, never the host's; broadcasts are count-nudges, not payloads
- [ ] Telemetry handlers and probe emissions detach/no-op cleanly on session end (§8.2)
- [ ] Probe macro verifiably compiles to `:ok` when disabled (assert on expanded AST or beam chunks)
- [ ] File sink: off by default, truncated previews only (§8.6), no full terms on disk
- [ ] Timeline honesty label present when only snapshot-diff events feed it
- [ ] Sobelow clean on the new UI surface (`--exit low`)
- [ ] Every panel interaction has a documented headless equivalent (B9)
- [ ] `mix check` green; coverage threshold met

## Findings

| # | Severity | File | Finding | Resolution |
|---|---|---|---|---|

## Sign-off

- Reviewed by: _
- Date: _
