# Tracer (v0.3) — Discovery

> Component doc set for roadmap release **v0.3 — Tracer (Layer 2)**
> ([roadmap.md](../roadmap.md)). Companions: [implementation.md](implementation.md),
> [code-review.md](code-review.md).

**Scope:** OTP 27+ trace sessions on subscribe/unsubscribe MFAs, match-spec narrowing,
receiver topology, recon-style budgets, `left_by_death`, Timeline upgrade, session/budget UX.

## Questions to answer

- [x] **A5** — receiver topology: per-session receiver + off-heap queue + drop-oldest (validated with micro-benchmark)
- [x] **A8** — confirm no needed trace-session API is OTP 28+; else revisit floor
- [x] **B5** — pre-arm preview UI: exactly what will be attached + budget, before confirm
- [x] Match-spec topic-prefix filtering: composition when a session traces multiple prefixes
- [x] User-added wrapper MFAs (e.g. `MyApp.Stations.subscribe/1`): validation and UI entry
- [x] Budget defaults: max events ~1 000 / ~60s / events-per-sec — confirmed against churn benchmark
- [x] Foreign-tracer coexistence test plan: run alongside LiveDebugger and recon simultaneously
- [x] Caller attribution: what stack context is capturable at acceptable cost?

## Settled designs (2026-08-16, evidence: [spikes/t1_trace_sessions.exs](spikes/t1_trace_sessions.exs), 12/12 on OTP 29)

### The load-bearing spike finding: trace BOTH arities, `:global` only

`Phoenix.PubSub.subscribe(pubsub, topic)` is the arity-2 **default-args wrapper**,
which reaches `subscribe/3` via a *local* call that global call-tracing never sees —
a global pattern on `/3` alone traces **nothing** for the common call form. The
tracer arms both `subscribe/2` and `subscribe/3` (and both `unsubscribe` arities)
with `:global`, which is also self-consistent: external-only tracing means
`{:caller}` names the real caller (not the wrapper) and the wrapper's internal call
to `/3` can't double-count. The same rule applies to user-added wrapper MFAs.

### Caller attribution: the `{:caller}` match-spec action

`[{:message, {{:"$1", {:caller}}}}]` delivers `{topic, {m, f, a}}` per call — exact,
VM-native, effectively free. Deeper stacks (`:process_dump`) rejected: cost and noise
(consistent with A9's chains-only-in-Inspector rule). Trace events carry
`meta: %{caller: mfa}`, render badge-free (source `:trace`), and the kind/source
axes absorb them with zero Timeline changes.

### Prefix filtering at the trace layer — confirmed, and composition

`binary_part/3` works in match-spec guards: 1 000 non-matching subscribes produced
**zero** trace messages. Multiple prefixes per session compose as one match spec with
an `orelse` chain of prefix guards (one `:trace.function` call per MFA, N guards).
Empty prefix list = trace all topics (budgets protect).

### A5 — receiver topology, validated

Per-session passive receiver (`message_queue_data: :off_heap`) created before
`session_create` and named as its tracer. Benchmark: a pathological hot loop (5 000
subscribe/unsubscribe rounds in 11ms untraced) ran at **1.79× overhead** with the
receiver absorbing **all 5 000 events (~235k ev/s)** — keep-up is not the risk;
unbounded *retention* is. Drop design: the receiver samples its own queue length per
drain; above a high-watermark it consumes-and-counts instead of forwarding until
below a low-watermark, then emits `[:wiretap, :collector, :dropped]` with the count
(the Timeline's dropped counter, reserved in the A3 taxonomy, lights up).

### Coexistence — proven for sessions, test plan for CI

Two sessions tracing the *same MFA* both received every event; destroying one left
the other intact. CI test plan (implementation must include): (1) two wiretap-style
sessions on the same pattern, (2) a wiretap session alongside a **legacy global**
`:erlang.trace_pattern` user, asserting neither clobbers the other, (3) teardown
leaves zero trace flags (assert via `:trace.info/3`). Testing against literal
LiveDebugger/recon deps is deferred to the dogfood environment — the session
isolation these tests prove is the mechanism their coexistence relies on.

### A8 — OTP floor holds

Everything used (`:trace.session_create/3`, `session_destroy/1`, `function/4`,
`process/4`, `info/3`) is documented "since OTP 27.0"; nothing needed is 28+. Spike
ran on 29; the CI OTP 27 cell becomes the durable enforcement the moment tracer
tests land (per the A8 support policy: the floor we declare is the floor we test).

### Budgets

Keep 1 000 events / 60s defaults; add the third bound from §3 rule 3: `max_rate`
(default **250 events/sec**, measured over 1s windows by the receiver). The
benchmark showed a hot loop can emit ~235k ev/s — rate is the bound that actually
protects the host, and it auto-detaches like the others (`:expired`, bound
`:max_rate` in the budget-exhausted telemetry).

### Wrapper MFAs and B5 pre-arm preview

`watch/2` gains `trace: [mfa]` (validated via `Code.ensure_loaded?` +
`function_exported?`; unknown MFA refuses the session loudly). Wrapper calls can't
be prefix-filtered (arg shapes unknown) — budgets protect; docs say so. B5: the UI's
arm flow renders exactly what will be attached — the MFA list, prefix filters, and
all three budget bounds — before the confirm button; while armed, a countdown plus a
live event/rate meter; `:expired` sessions keep their "what tripped" bound visible
(already in the stop telemetry).

## Decision log

| Date | ID | Decision |
|---|---|---|
| 2026-08-16 | — | **Spike T1: 12/12.** Both-arities/:global rule (default-args wrappers make local calls — the spike's headline catch), `{:caller}` attribution, binary_part prefix guards (zero messages for non-matching traffic), two-session coexistence + destroy isolation, 1.79× hot-loop overhead with a receiver absorbing 235k ev/s |
| 2026-08-16 | A5 | Per-session off-heap passive receiver; watermark consume-and-count drop mode emitting `[:wiretap, :collector, :dropped]` |
| 2026-08-16 | A8 | Floor holds: all used `:trace` APIs are OTP 27.0; CI's 27 cell enforces once tracer tests land |
| 2026-08-16 | B5 | Pre-arm preview: attachments + prefixes + all three budgets before confirm; countdown + rate meter while armed |
| 2026-08-16 | — | Budgets gain `max_rate` (default 250 ev/s, 1s windows) as the third bound; wrapper MFAs via validated `trace:` option, unfiltered but budget-protected |
