# Wiretap — Implementation Discovery

> Discovery session doc, started 2026-08-14. Companion to [architecture.md](architecture.md).
> Purpose: pressure-test the architecture before writing code, with three focus areas:
> **(A)** is the layered PubSub + Telemetry-first architecture right, with tracing as
> later expansion; **(B)** UI/UX for the panels; **(C)** the quality/tooling baseline
> (formatting, credo, sobelow, hex audit, and friends). Questions carry IDs (A1, B2, C3…)
> so answers can be recorded inline as they land.

---

## 0. Facts verified this session (no longer open)

- **The name `wiretap` is free.** `https://hex.pm/packages/wiretap` returns 404 and a
  GitHub/web search finds no Elixir project with the name. §9 step 0 is satisfied —
  claim it early by publishing a stub or at least reserving the repo name.
- **PubSub-over-Registry assumption confirmed.** `Phoenix.PubSub.subscribe/3` delegates
  directly to `Registry.register(pubsub, topic, metadata)` and `unsubscribe/2` to
  `Registry.unregister/2`, with the registry named by the pubsub atom and partitioned
  via `:registry_size` (default `:pool_size`). Layers 1 and 2 attach to real,
  stable-ish seams. One wrinkle discovered: phoenix_pubsub now exposes a `:group_by`
  option (`:pid` | `:key`) that changes how subscriptions are stored — folded into A1.
- **The telemetry gap is real.** Current `Phoenix.PubSub` source emits zero telemetry
  events. The "no standard hook exists" premise of the whole tool holds.
- **Toolchain headroom.** Local dev machine runs Elixir 1.19.5 / OTP 29. The OTP 27
  floor (trace sessions) is now two majors behind current — not a bleeding-edge ask.
- **Sobelow runs on plain libraries but is Phoenix-centric.** It needs no Phoenix
  project structure, but most check categories (XSS, router config, CSRF…) target
  Phoenix apps. Expect near-zero findings on the headless core and real value once the
  LiveView UI ships. Verdict: include from day one (cheap, and the UI is coming) — C3.
- **`mix hex.audit` and `mix deps.audit` are complementary, not alternatives.**
  `hex.audit` (built into Hex) flags *retired* package versions; `mix_audit`'s
  `deps.audit` cross-references the lockfile against the community security-advisory
  database (CVEs) and fails the build. A library that wants to be trusted in host apps
  runs **both** — C4.

---

## A. Architecture validation — is layered, PubSub + Telemetry first, right?

### A1. Registry coupling: how do we survive phoenix_pubsub internals changing?

The load-bearing risk of the whole design. Layer 1's `Registry.select/2` match spec and
layer 2's trace patterns both assume the *current* storage shape, which is semi-private.
The new `:group_by` option proves the shape is actively evolving.

- **Decide:** pin supported phoenix_pubsub versions tightly (`~> 2.1`), or
  feature-detect at runtime (probe the registry entry shape at session start and refuse
  loudly on mismatch)?
- **Recommendation:** both — a conservative version requirement *plus* a startup
  shape-probe that degrades gracefully ("layer 1 unavailable: unrecognized registry
  layout") instead of returning silently wrong data. Wrong-but-confident output from a
  debugging tool is worse than no tool.
- **Spike:** a test matrix exercising `Snapshot` against phoenix_pubsub 2.0 / 2.1 /
  2.2, with both `:group_by` values and `registry_size > 1`.

### A2. Roadmap order: should the telemetry bridge move ahead of the tracer?

The architecture doc ships tracing (L2) in v0.2 and the telemetry bridge (§4.1) in
v0.3. But by the doc's own cost ranking, the bridge is the *cheapest, safest*
attachment (a function call when attached, nothing when not), while the tracer is
flagged as "the highest-risk component." A PubSub-and-telemetry-first sequencing would
be:

| | Current plan | Proposed reorder |
|---|---|---|
| v0.1 | Snapshot + diff, LiveDashboard page | same |
| v0.2 | **Tracer (L2)**, Timeline | **Telemetry bridge**, Timeline (fed by snapshot diffs + telemetry + monitors) |
| v0.3 | Wiretap panel + telemetry bridge + probes | **Tracer (L2)** upgrades the Timeline in place (caller attribution, no polling gap) |

- **What this buys:** two full releases of real-world usage, session-manager hardening,
  and Timeline UI iteration before any trace flag is ever set — and the Timeline event
  model gets designed around *heterogeneous* sources (diffs, telemetry, probes, DOWNs)
  from the start rather than retrofitted.
- **What it costs:** caller attribution and sub-poll-interval events arrive one release
  later; the v0.2 Timeline is "good" not "exact."
- **Decide:** adopt the reorder? **Recommendation: yes** — it matches the safety
  contract (§8) and de-risks the scariest component by giving it existing scaffolding
  to land in. The probe macro (§4.4) is also nearly free and could ride along in v0.2.

### A3. Should Wiretap emit its own telemetry?

`[:wiretap, :session, :start | :stop | :expired]`, `[:wiretap, :budget, :exhausted]`,
etc. Costs ~nothing, lets host apps alarm on "someone left a trace session armed in
staging," and is the idiomatic citizenship move for a tool whose premise is "PubSub
should have emitted telemetry." **Recommendation: yes, from v0.1.** Decide the event
taxonomy before the session manager is written, not after.

### A4. Is snapshot-diffing good enough as the v0 Timeline backend?

The reorder in A2 leans on synthetic `:joined`/`:left` events from ~1s polling. Unknown:
how often do real apps subscribe+unsubscribe inside one poll interval (modal
open/close, LiveView remounts on nav)?

- **Spike:** in the dev harness, hammer modal-style subscribe/unsubscribe cycles and
  measure the miss rate at 1s / 250ms / 100ms poll intervals, and the select cost at
  each on a registry with ~10k entries.
- **Decide:** default interval, whether it auto-tightens while a Timeline panel is
  focused, and the documented honesty note ("events between polls are invisible until
  layer 2 is armed").

### A5. Trace-receiver topology (carried from §11.2)

One receiver process per session (isolation, simple teardown) vs one shared receiver
with routing (one tracer identity per traced MFA — relevant because a *traced process +
flag combo* can still conflict within a single trace session). Also: backpressure
policy when the Collector or UI is slow — drop-and-count is the recon-proven answer;
blocking a trace receiver is never acceptable.
**Recommendation to test:** per-session receiver, `:message_queue_data :off_heap`,
drop-oldest with a visible "N events dropped" counter in the UI.

### A6. seq_trace under trace sessions — verify the constraint before v0.4 designs around it

Assumption to verify in a spike: the `seq_trace` *system tracer* remains a per-node
singleton even in the OTP 27+ session world (sessions cover call/receive tracing; it's
unclear they do anything for seq_trace). If true, Broadcast Trace needs the
serialize-requests design of §3.3b *and* must detect a foreign system tracer (another
tool owning it) and refuse loudly per §8.3.

### A7. Adapter reality check: what do L1/L2 see under the Redis adapter?

Hypothesis: local subscriptions still live in the local Registry regardless of adapter
(adapters handle inter-node transport), so Roll Call and Timeline are correct *per
node* under any adapter, and only Broadcast Trace's cross-node story differs.
**Spike:** confirm with the Redis adapter README/source; if the hypothesis holds,
document "node-local truth, adapter-agnostic" as a v1 guarantee, which is a stronger
statement than §4.5's hedge.

### A8. Version floor: OTP 27 / Elixir 1.17 — still right?

OTP 29 is current; 27 as floor is generous, not aggressive. **Recommendation:** keep
OTP 27 / Elixir 1.17 floor, CI-test the full matrix through the current stable pair (C7).
Revisit only if a needed trace-session API turns out to be 28+.

**Support policy (decided 2026-08-15): the floor we declare is the floor we test.**
`elixir: "~> 1.17"` in mix.exs *enforces* the floor (Mix refuses older hosts) but
verifies nothing — code using a 1.18+ stdlib function would still install fine on 1.17
and fail at runtime. The CI matrix's oldest cell is what keeps the declaration honest;
shrinking the matrix means raising the floor to match. Note the asymmetry: the **OTP
floor cannot be enforced** by mix/hex at all (there is no `otp:` requirement field) —
it is enforced at runtime by the tracer's loud-refusal path when `:trace` sessions are
unavailable (§8.3), and verified pre-merge only by the OTP 27 CI cell. Raising floors
trades away adoption (host teams lag the toolchain), so floors move only when an API
forces it, never for convenience.

### A9. Pid labeling depth (carried from §11.4)

LiveView module attribution is cheap and high-value. Full `$ancestors`/`$callers`
chains are likely noise in the table but gold in a detail view. **Recommendation:**
label = best single identity (registered name > LiveView module > initial_call);
chains live only in the Process Inspector detail pane. Validate against the harness.

---

## B. UI/UX

### B1. Does the v0 LiveDashboard page survive into v1? (carried from §11.5)

The LiveDashboard page is a launch accelerant and a discovery surface (people already
have LiveDashboard open), but it's a second UI to maintain and can't host the richer
panels. **Options:** (a) keep both forever; (b) LiveDashboard page becomes a permanent
*Roll-Call-only* teaser with a "open full Wiretap" link; (c) retire it at v1.
**Recommendation: (b)** — cheap to maintain if it's frozen at read-only Roll Call, and
it's free marketing inside every host app. Decide before v0.2 so effort isn't sunk
into dashboard-page features that will be thrown away.

### B2. Information architecture: entry point and navigation

Five panels is a lot of chrome for a debugging tool. The natural user journey is a
funnel: *Roll Call → (click topic) → Timeline filtered to it → (click pid) → Process
Inspector / Wiretap on that pid*. **Decide:** are panels top-level tabs (LiveDashboard
idiom) or is Roll Call the home screen with everything else reached by drill-down?
**Recommendation:** Roll Call as home + drill-down, with Timeline as the only other
top-level tab; Wiretap/Inspector/Broadcast-Trace open as contextual panes. This makes
the empty-state story (B6) and the "one obvious first action" story much better than
five equal tabs.

### B3. Live-stream ergonomics on the Timeline and Wiretap panels

Scrolling live logs are famously miserable. Required behaviors to spec before building:
follow-mode toggle (auto-pause when the user scrolls up, like `journalctl -f`
emulators); rate-limited re-render (batch the "N new events" nudges, never re-render
per event); a visible dropped/truncated counter tied to A5's backpressure policy;
filter-before-buffer vs filter-at-render (recommend: budget counts *captured* events,
filters are render-time so changing a filter doesn't lose data).

### B4. Scale UX for Roll Call

A real app has hundreds of topics; the motivating case has per-record topics
(`"station:<id>"`). A flat table dies here. **Decide:** grouping strategy —
prefix-collapsed tree (`station:*  (214 topics, 214 subscribers)`) with expand, plus
a filter box that accepts a prefix. Wildcard/regex filtering is a v-later nicety.
Sort by subscriber count descending as default (anomalies float to top).

### B5. Session/budget UX — make the safety contract visible

Budgets (§3 L2 rule 3) are an implementation guarantee that should be a *UI feature*:
arming any trace shows exactly what will be attached and the budget (events / rate /
seconds) *before* the confirm button; a live countdown + event-count meter while armed;
`:expired` sessions stay visible with a "what tripped" reason. One-click presets
("Watch this topic for 60s") over raw knob-turning. This is the main trust-building
surface for a tool that asks permission to trace production-adjacent systems.

### B6. Empty states are the product

"Is it even wired?" (§1 failure mode 4) means *zero subscribers on a topic* is a
first-class answer, not a blank table. Spec: searching/filtering to a topic with no
subscribers renders an explicit "nobody is listening to `X`" state, ideally with "arm
Timeline to catch a future subscriber" as the suggested next action. Same care for:
no sessions yet, budget exhausted, layer unavailable (A1's shape-probe failure).

### B7. Payload preview vs the never-store-full-terms rule

§8.6 says truncated `inspect` only. Users will immediately want "expand." **Decide:**
is expand (a) unavailable, (b) re-inspects with larger limits *at render time from the
stored term* — which violates §8.6 since the full term must be stored — or (c) a
per-session opt-in capture setting ("full payloads: off / 10KB / unlimited-dev-only")
chosen at arm time? **Recommendation: (c)** — the storage rule becomes a budget knob
with safe defaults rather than an absolute, keeping the production profile strict
(§8.5 already disables 3a payload capture there).

### B8. Visual/asset strategy for the standalone endpoint

The LiveDebugger pattern (own endpoint, assets precompiled into `priv/static`, zero
host esbuild coupling) is settled. Still open: CSS approach (hand-rolled vs Tailwind
compiled at package-build time — either works when precompiled; pick whichever keeps
contributor setup simplest), dark mode (dev tools live next to terminals — support it
from v1, it's much cheaper now than retrofitted), and one identity color so Wiretap
tabs are instantly distinguishable from LiveDashboard/LiveDebugger tabs.

### B9. Headless parity as a UX principle

Every panel interaction should have a documented public-API equivalent
(`Wiretap.topics/1`, `Wiretap.watch/2`, `Wiretap.trace_broadcast/2`…) so iex users and
ExUnit tests are first-class citizens, not an afterthought — the library was born from
a CI test, and `Wiretap.Snapshot.topics/1` as a test assertion helper is an explicit
v0.1 deliverable. **Decide:** the iex-facing API surface for each panel *as part of
designing the panel*, and consider `Wiretap.Test.assert_subscribed/3`-style ExUnit
helpers as their own selling point.

---

## C. Tooling and quality gates

### C1. Formatting: `mix format` + Styler

`{:styler, "~> 1.2", only: [:dev, :test], runtime: false}` as a formatter plugin, per
the §9 baseline. CI runs `mix format --check-formatted`. No open question — adopt.

### C2. Credo

`{:credo, "~> 1.7", ...}`, run as `mix credo --strict` in CI. **Decide:** commit a
`.credo.exs` early with any consciously-disabled checks documented inline, so
contributor PRs don't relitigate style. Adopt.

### C3. Sobelow

Verified: runs fine on non-Phoenix projects but its checks are Phoenix/web-centric, so
it earns little on the headless core and real value once the LiveView UI lands.
**Recommendation:** add now anyway — `mix sobelow --exit low` in CI with a committed
`.sobelow-conf` — so the gate already exists the day `wiretap/ui/` appears. A tool
whose pitch includes "safe to run near production" cannot ship a web UI that was never
security-scanned.

### C4. Dependency auditing: both `hex.audit` and `mix_audit`

Verified as complementary: `mix hex.audit` (built-in) catches retired versions;
`{:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}` provides
`mix deps.audit` against the security-advisory CVE database. Run both in CI, plus
`mix deps.unlock --check-unused` to keep the lockfile honest. Adopt all three.

### C5. Dialyzer — and a question about the new Elixir type system

`{:dialyxir, "~> 1.4", ...}` with PLT caching in CI (the expensive part; cache on
`{OTP, Elixir, lockfile-hash}`). Open question: Elixir 1.19's built-in type checking
now catches a growing class of what Dialyzer catches, at zero setup cost — but our
floor is 1.17, so built-in inference is a bonus layer on newer compilers, not a
replacement. **Recommendation:** ship specs on all public functions, run Dialyzer in
CI, and treat compiler type warnings as errors (`--warnings-as-errors`) on the newest
matrix cell only.

### C6. Docs and coverage gates

- `{:ex_doc, "~> 0.34", only: :dev}` — with `groups_for_modules` mirroring the layer
  structure, and the architecture doc's panel table reused in the README.
- **Doc coverage:** `{:doctor, ...}` enforces @moduledoc/@doc/@spec coverage — worth a
  yes/no decision; **recommendation: yes** for a library whose audience is strangers.
- **Test coverage:** `{:excoveralls, ...}` with a modest initial `minimum_coverage`
  (the Tracer will have hard-to-cover branches); doctests wherever examples appear.

### C7. CI shape

GitHub Actions: lint job (format, credo, sobelow, audits, unused-deps) on one modern
pair + test job on the support matrix — OTP {27, 28, 29} × Elixir {1.17, 1.18, 1.19}
compatible pairs, `warnings-as-errors` on the newest cell (C5). Dialyzer as its own
cached job. Dependabot (or Renovate) for both hex deps and actions. **Open question:**
does the `dev/harness` Phoenix app get its own CI job (compile + its LiveView tests),
or is it explicitly untested scaffolding? **Recommendation:** compile-check it in CI at
minimum — a broken harness kills contributor onboarding.

### C8. One entry point: `mix check` vs aliases

**Decide:** adopt `ex_check` (parallel runner for all of the above with one command)
vs a hand-rolled `mix check` alias. **Recommendation:** `ex_check` — it exists
precisely for this stack (formatter, credo, dialyzer, sobelow, audits, tests, doctor),
gives contributors one command that matches CI, and its config file documents the
quality bar in-repo.

### C9. Release/publish hygiene

- `mix hex.build` dry-run in CI on every PR (catches missing package metadata early,
  not at publish time).
- CHANGELOG.md (Keep-a-Changelog format) from the first commit; git tags per release.
- License: MIT (per §11.7) — decide now, it's in `mix.exs` package metadata from day 1.
- **Open question (carried from §11.7):** the origin project dogfoods a path dep
  before the first hex publish? **Recommendation: yes** — publish v0.1 only after its
  test suite has replaced the hand-rolled `Registry.keys/2` helper with
  `Wiretap.Snapshot` and lived with it for a sprint.

---

## D. Decision log

Record answers here as they land, newest first.

| Date | ID | Decision |
|---|---|---|
| 2026-08-15 | B3, B4, B6, B8, B9 | **Resolved in the v0.2 design session** (follow-mode/batching, prefix grouping, empty-state inventory, hand-rolled CSS + phosphor-green identity, headless-parity rule), plus telemetry bridge, probe gate (deviation from §4.4 dev-default: explicit opt-in), monitor-based left_by_death, and the file-sink format. Details: [timeline/discovery.md](timeline/discovery.md) |
| 2026-08-15 | A3 | **Resolved**: Wiretap telemetry taxonomy fixed (session start/stop as spans, budget-exhausted as its own alarm event, registry-incompatible signal). Full table: [core/discovery.md](core/discovery.md) |
| 2026-08-15 | A9 | **Resolved**: pid label = registered name → `$initial_call` (LiveView special-cased) → `inspect(pid)`; ancestor/caller chains only in the v0.4 Inspector. Details: [core/discovery.md](core/discovery.md) |
| 2026-08-15 | A8 | **Resolved — floors stay at OTP 27 / Elixir 1.17.** Support policy: declared floor = tested floor (oldest CI cell verifies the mix.exs claim); OTP floor is runtime-enforced (loud refusal) + CI-verified since mix/hex cannot gate on OTP; floors move only when an API forces it |
| 2026-08-14 | A6 | **Spike passed** (12/12, OTP 29): seq_trace system tracer remains a per-node singleton under trace sessions — arbitration design confirmed necessary; token propagates through PubSub broadcast to all subscribers with timestamps; foreign tracer detectable; coexists with call-trace sessions. Details: [bootstrap/discovery.md](bootstrap/discovery.md) |
| 2026-08-14 | A4 | **Spike run**: select at 10k subs ≈ 1.8ms (cost is a non-issue); 1s polling misses 54% of ~500ms subscribe/unsubscribe episodes and 93% of ~100ms ones. Default 1s, auto-tighten to 250ms while a panel is focused, honesty label required. Details: [bootstrap/discovery.md](bootstrap/discovery.md) |
| 2026-08-14 | A1 | **Spike passed** (84/84): select-based snapshot, unsubscribe removal, and death cleanup identical across phoenix_pubsub 2.0.0–2.2.0 and all partition/`group_by` configs. Keep `~> 2.1` pin + startup shape-probe. Details: [bootstrap/discovery.md](bootstrap/discovery.md) |
| 2026-08-14 | A2 | **Adopted the reorder**: telemetry bridge + probes ship in v0.2, tracer moves to v0.3. Tracked in [roadmap.md](roadmap.md), which supersedes architecture.md §10 |
| 2026-08-14 | — | Name `wiretap` verified free on hex.pm and GitHub |
| 2026-08-14 | C1, C2 | Adopt format+Styler and credo --strict (no dissent expected) |

## E. Spike queue (ordered)

1. **A1** registry-shape matrix test (phoenix_pubsub 2.0/2.1/2.2 × `:group_by` × partitions) — gates everything.
2. **A4** poll-interval miss-rate + select-cost measurement in the harness — decides whether the A2 reorder's v0.2 Timeline is honest enough.
3. **A6** seq_trace-under-sessions singleton check — one iex session, an afternoon, de-risks the v0.4 headline feature.
4. **A5** receiver-topology micro-benchmark — only after the session manager skeleton exists.
5. **A7** Redis-adapter subscription locality — reading source may suffice, no code needed.
