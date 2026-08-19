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
- [x] Docs site: hexdocs-only vs dedicated site — **both** (hexdocs API reference + GitHub Pages showcase, see decision log); guides inventory still open
- [ ] Final doctor/excoveralls thresholds
- [ ] Telemetry events for prod observability of Wiretap itself (armed sessions, budget trips)

## Decision log

| Date | ID | Decision |
|---|---|---|
| 2026-08-19 | — | **Pages pipeline: GitHub Actions deployment, no custom domain.** Pages source set to "GitHub Actions"; a workflow builds the site source and deploys via `actions/upload-pages-artifact` + `actions/deploy-pages` — no `gh-pages` branch, no committed build output, and never the `/docs`-folder mode (that directory is the design-doc set). Site lives at the default `curtisault.github.io/wiretap/`, so links/assets must be prefix-aware. The workflow ships with the site in v1.0 (nothing to deploy until then, and Pages needs the repo public — which happens at the v0.1 publish). Still open: guides inventory |
| 2026-08-19 | — | **Docs strategy: both surfaces, each doing what it's best at.** Hexdocs stays the canonical API reference — published as usual on `mix hex.publish`, organized with `groups_for_modules` by layer; it's where Elixir developers look first and ex_doc already gates `mix check`. Separately: hand-built static artifacts on GitHub Pages, themed like the Wiretap UI (phosphor green, same visual identity as the panels) — the aesthetically strong engineering-docs showcase (flow diagrams, safety contract, guides) that stock ExDoc output can't be. The two cross-link (README + hex metadata → Pages; Pages → hexdocs for API detail). The v1.0 discovery session settles the guides inventory (getting started, safety contract, production usage) and the build pipeline (likely a CI job publishing to Pages) |
