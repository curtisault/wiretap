# Production (v1.0) — Discovery

> Component doc set for roadmap release **v1.0 — Production-possible**
> ([roadmap.md](../roadmap.md)). Companions: [implementation.md](implementation.md),
> [code-review.md](code-review.md).

**Scope:** production profile, docs site, multi-node research spike, final quality gates.

## Questions to answer

- [ ] **A7** — Redis-adapter locality: confirm "node-local truth, adapter-agnostic" and document as guarantee
- [ ] Production profile: exact budget multipliers, which features hard-disabled vs confirm-gated
- [ ] Per-session confirmation UX in production profile: who confirms, how is it audited?
- [ ] Multi-node: `:erpc` fan-in design sketch — v1.0 ships the research writeup, not the feature
- [ ] Docs site: hexdocs-only vs dedicated site; guides inventory (getting started, safety, prod usage)
- [ ] Final doctor/excoveralls thresholds
- [ ] Telemetry events for prod observability of Wiretap itself (armed sessions, budget trips)

## Decision log

| Date | ID | Decision |
|---|---|---|
