# Wiretap — PubSub Listener Architecture

> Planning document for a standalone open-source library. Drafted 2026-08-14 out of the
> universal-search silo-set work, where validating PubSub subscription hygiene (subscribe
> only while a modal is open, only for one well, never for unassigned records) required
> hand-rolled `Registry` inspection, LiveDebugger callback traces, and a CI test that
> reads the PubSub registry directly. No library exists for this; this document is the
> blueprint for building one. A deep implementation-discovery session follows later —
> this captures architecture, attachment mechanics, and project bootstrap only.

---

## 1. Vision

**Wiretap answers three questions about a running BEAM application, live:**

1. **Who is listening?** — every `Phoenix.PubSub` topic and the processes subscribed to
   it, updated as subscriptions come and go (the *Roll Call* panel).
2. **When did they start/stop listening, and who asked?** — subscribe/unsubscribe as
   *events* with timestamps, calling process, and stack context (the *Timeline* panel).
3. **What are they hearing?** — the actual messages a subscriber receives, and the full
   fan-out tree of a single broadcast across processes and nodes (the *Wiretap* and
   *Broadcast Trace* panels).

The failure modes it exists to catch, all seen in real work:

- Subscription leaks: a LiveView subscribes on modal open but a close path forgets to
  unsubscribe; the process accumulates topics and ignored messages.
- Stale consumers: a payload shape changes and a subscriber's catch-all clause silently
  swallows the new shape forever (invisible in logs, invisible on the websocket).
- Phantom fan-out: one broadcast wakes fifty processes that pattern-match it away —
  wasted schedulers no one ever sees.
- "Is it even wired?": an event fires and *nothing* is subscribed to the topic.

### 1.1 Naming

`wiretap` (hex: `wiretap`, module namespace `Wiretap`). The layered design settles the
wiretap-vs-rollcall question: **Roll Call is a panel inside Wiretap** — layers 1–2 below
are roll-call semantics (who is subscribed, when they joined/left), layer 3 is the
literal wiretap (what they hear). Tagline: *"See who's listening on your Phoenix.PubSub
topics — live."*

Verify availability before `mix new`: `https://hex.pm/packages/wiretap` and a GitHub
search. Fallback names from the same naming session: `party_line`, `earshot`,
`roll_call`.

### 1.2 Prior art and why none of it is this

| Tool | What it gives | Why it isn't this |
|---|---|---|
| LiveDebugger (Software Mansion) | LiveView callback traces, assigns, component tree, own endpoint on :4007 | Traces LiveView callbacks only; no registry/topic awareness. Proves messages *arrive* but can't list subscriptions. |
| LiveDashboard | Processes, ETS tables (incl. the PubSub Registry partitions, raw) | No topic grouping, no events, no message capture. Unusable for this in practice. |
| recon / recon_trace | Safe production tracing with rate limits | Library API, no UI, no PubSub awareness. We steal its overload-protection design. |
| Observer / observer_cli | Whole-VM process view | Wrong altitude entirely. |
| `Registry.select/2` one-liners | Point-in-time subscriber snapshots | The DIY baseline. Wiretap layer 1 is this, productized. |

Structural gap: `Phoenix.PubSub` emits **no telemetry events** for subscribe /
unsubscribe / broadcast, so the standard dashboard-plugin route has nothing to hook.
Any real implementation must go through Registry introspection and BEAM tracing.

---

## 2. Architecture overview

```
┌─────────────────────────────────────────────────────────────────────┐
│ HOST APPLICATION (unmodified)                                       │
│                                                                     │
│   Phoenix.PubSub ──> Registry (partitioned ETS)                     │
│   subscribers: LiveViews, GenServers, DataServers, channels…        │
└──────────┬─────────────────────┬────────────────────────────────────┘
           │ introspection       │ BEAM tracing (from outside,
           │ (Registry.select)   │  runtime, zero host code)
┌──────────▼─────────────────────▼────────────────────────────────────┐
│ WIRETAP CORE (plain Elixir library, own supervision tree)           │
│                                                                     │
│  Snapshotter        Tracer                 Collector                │
│  (L1: polling       (L2: call trace        (ring buffers in ETS,    │
│   + diffing)         L3: msg/seq trace)     per capture session)    │
│                          │                      │                   │
│  Session manager ────────┴──────────────────────┘                   │
│  (attach/detach, budgets, auto-expiry, trace-session isolation)     │
└──────────┬──────────────────────────────────────────────────────────┘
           │ Wiretap.API (pure functions + PubSub of its own for UI)
┌──────────▼──────────────────────────────────────────────────────────┐
│ UI (optional, dev-only)                                             │
│  v0: LiveDashboard custom page                                      │
│  v1: standalone LiveView endpoint on its own port (LiveDebugger     │
│      pattern) — panels: Roll Call · Timeline · Wiretap · Broadcast  │
│      Trace                                                          │
└──────────────────────────────────────────────────────────────────────┘
```

Governing idea: **the host app is never modified and never pays while the tool is
idle.** All attachment happens from outside (introspection and tracing), on demand, with
budgets. The one exception is the explicit opt-in probe macro (§4.4), which compiles to
a no-op outside dev.

---

## 3. The three attachment layers

Escalating in power and in cost. Each layer is independently useful; a capture session
composes them.

### Layer 1 — Registry snapshots (state; free)

**Answers:** what topics exist right now, and which pids subscribe to each.

**Mechanism:** `Registry.select/2` against the PubSub registry (its name is the
`Phoenix.PubSub` name, e.g. `TSS.PubSub`), the same call our CI test uses:

```elixir
Registry.select(pubsub, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
|> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
```

The Snapshotter polls on an interval (default ~1s while a UI session is open, 0 when
not), diffs consecutive snapshots, and emits synthetic `:joined` / `:left` events for
the Timeline when layer 2 is not active. Enrichment per pid, all cheap point reads:
`Process.info(pid, [:registered_name, :dictionary, :initial_call])` — the process
dictionary's `:"$initial_call"` / `:"$ancestors"` identifies LiveViews, and
`Phoenix.LiveView` pids can be labeled with their view module.

**Footprint:** ETS reads only. Registry is partitioned (`:registry_size`); the select
walks all partitions — on registries with tens of thousands of subscriptions, throttle
or sample. Zero risk to the host.

**Limits:** point-in-time only. Sub-poll-interval subscribe+unsubscribe pairs are
invisible; no caller attribution. That's what layer 2 is for.

### Layer 2 — Call tracing (events; the Roll Call backend)

**Answers:** subscribe/unsubscribe as real events — when, by which process, with which
arguments — with no polling gap.

**Mechanism:** BEAM call tracing on exact MFAs, attached at runtime from outside:

- `Phoenix.PubSub.subscribe/3`, `Phoenix.PubSub.unsubscribe/2`
- `Registry.register/3`, `Registry.unregister/2` (catches direct-Registry users)
- optionally the host's own wrapper functions (e.g. `TSS.SiloSets.subscribe/1`), added
  per-session by the user from the UI — this is the "inject a listener anywhere without
  injecting code" capability: the injection point is a trace pattern, not a code change.

Non-negotiable implementation rules, learned from the tools that do this well:

1. **OTP 27+ trace sessions** (`:trace.session_create/3` et al.), not the legacy
   `:dbg`/`:erlang.trace` globals. Sessions are isolated: Wiretap tracing cannot clobber
   or be clobbered by LiveDebugger, recon, or an operator's ad-hoc `:dbg` — the legacy
   API is effectively single-tenant per traced process and *will* collide in any app
   that also runs LiveDebugger (ours does). This decides the minimum OTP version.
2. **Match specs narrow everything.** Trace only the listed MFAs; use match-spec guards
   to filter by topic prefix at the trace layer (e.g. only `"silo_sets:" <> _`) so
   uninteresting calls never generate trace messages at all.
3. **recon-style overload protection.** Every session carries a budget: max events
   (default ~1 000), max duration (default ~60s), max events/sec; hitting any bound
   detaches the session automatically and marks it `:expired` in the UI. An unbounded
   tracer on a hot function is how a debugging tool takes down the app it debugs.
4. **Unsubscribe-by-death is not a call.** Registry cleans up when a subscriber dies and
   no `unsubscribe` is ever called. The Collector monitors every pid it has seen
   (`Process.monitor/1`) and records `:DOWN` as a distinct `left_by_death` event —
   distinguishing "deliberately unsubscribed" from "process died" is precisely the
   signal needed when hunting leaks vs crashes.

**Footprint:** near-zero attached-but-quiet (match specs fail fast in the VM); bounded
by budget when loud. The tracer process is a dedicated receiver so trace messages never
land in an application mailbox.

### Layer 3 — Message tracing (payloads; the literal wiretap)

**Answers:** what a specific subscriber actually receives; and the complete fan-out of a
single broadcast.

Two distinct mechanisms:

**3a. Per-pid receive tracing.** `:erlang.trace(pid, true, [:receive])` (via the same
trace session) on *explicitly selected* pids only — never process groups, never
`:all`. The Collector filters received messages to those matching PubSub shapes /
selected topics, truncates payloads for display (`inspect(limit:, printable_limit:)`),
and honors the session budget. This shows the message a catch-all handler is silently
eating — the exact bug class that motivated the tool.

**3b. Broadcast fan-out via `:seq_trace`.** The killer feature no existing tool has.
`:seq_trace` propagates a token along message sends: stamp a token, run one
`Phoenix.PubSub.broadcast/3`, and every message it fans into — across processes *and*
nodes — carries the token; a `seq_trace` system tracer collects the delivery tree with
causal ordering and per-hop timestamps. Result: "this broadcast reached these 14
processes, in this order; these 3 matched no clause." Footprint is exactly zero when no
token is set. Constraints to design around: one seq-token context per stamping process
at a time, and the system tracer is a per-node singleton — the session manager owns it
and serializes broadcast-trace requests.

---

## 4. Additional BEAM attachment points

Considered for the "empower the user, small footprint" goal. First three are in scope.

### 4.1 `:telemetry.attach/4` — the universal listener

`Phoenix.PubSub` emits nothing, but the *host app* emits plenty (Ecto, Phoenix, Oban,
custom spans). A generic "attach to any telemetry event, stream into the session
timeline" panel costs ~nothing (telemetry handlers are free when unattached, a function
call when attached) and lets users correlate *"broadcast happened"* with *"query ran /
job enqueued"* on one timeline. Cheap to build, large payoff, keeps Wiretap useful even
where tracing is off-limits.

### 4.2 `:sys.install/2` — surgical OTP process hooks

Installs a debug function on one OTP-compliant process (GenServer, GenStage…), seeing
every message and state transition through the `:sys` debug facility — no global trace
machinery, no trace-session contention. The right tool for "attach to this one
DataServer and show me its state after each PubSub message." Ships as the *Process
Inspector* side panel: pick a pid from Roll Call → attach → watch. Auto-`:sys.remove`
on session end; same budgets as tracing.

### 4.3 Process monitors — lifecycle truth

Already required by layer 2 (death-vs-unsubscribe). Generalized: everything the UI has
ever shown gets monitored while the session lives, so the UI never renders a dead pid as
alive. Monitors are the cheapest primitive on this list.

### 4.4 Explicit probe macro — opt-in, compiled away

For the rare case where in-band context beats external attachment:

```elixir
require Wiretap.Probe
Wiretap.Probe.tap("silo_sets:#{well_id}", label: "modal open", meta: %{user: user.id})
```

Compiles to the event emission only when `config :wiretap, probes: true` (dev default);
compiles to literal `:ok` otherwise — the `dbg()` pattern, zero prod footprint, safe to
commit. Probes appear on the Timeline interleaved with traced events.

### 4.5 Explicitly out of scope (v1)

- `:erlang.system_monitor` (long schedules, large heaps) — Observer/recon territory;
  scope creep.
- Scheduler/allocator stats, `:msacc` — same.
- Distribution-wide aggregation UI — the core APIs are node-local; multi-node lands
  later via `:erpc` fan-in from the UI node, and `pg`/`Phoenix.PubSub.RedisAdapter`
  introspection is a research item, not a v1 promise.

---

## 5. Event pipeline and storage

- **Collector** per capture session: a GenServer owning a public-read ETS ring buffer
  (bounded, default 10k events; overwrite oldest). Trace messages, snapshot diffs,
  telemetry events, probe hits, and `:DOWN`s all normalize into one event struct:
  `%Wiretap.Event{at, kind, topic, pid, pid_label, payload_preview, session, meta}`.
- **UI updates** ride Wiretap's *own* `Phoenix.PubSub` instance (`Wiretap.PubSub`,
  started in the library's supervision tree) — never the host's, so the tool does not
  pollute the registry it is inspecting. The UI subscribes per session and re-renders
  from ETS; broadcasts carry only "new events, count N" nudges, not payloads.
- **Sessions** are first-class: named, budgeted, listable, and everything they attached
  (trace patterns, monitors, `:sys` hooks, telemetry handlers, seq tracer) is torn down
  by the session manager on stop, expiry, or crash (the manager traps exits and detaches
  in `terminate/2`; a supervisor restart re-arms nothing — sessions never auto-resume).

---

## 6. UI strategy

**v0 — LiveDashboard custom page.** ~50–100 lines: Roll Call table (topic → subscriber
count → pid list with labels) over layer 1 polling. Ships value in a weekend and forces
the core API into shape.

**v1 — standalone LiveView endpoint, the LiveDebugger pattern.** Own
`Wiretap.Endpoint` on its own port (default `4008`, one above LiveDebugger's 4007),
started from the library's supervision tree in dev only. Never touches the host router,
sessions, or auth; assets precompiled into `priv/static` (no host esbuild coupling).
Panels:

| Panel | Backing layers | Core interaction |
|---|---|---|
| **Roll Call** | 1 (+2 when armed) | Topic tree with live subscriber lists, filter by prefix, pid labels, click-through to Process Inspector |
| **Timeline** | 2 + monitors + probes + telemetry | Scrolling event log: joined / left / left-by-death / probe / telemetry, filterable |
| **Wiretap** | 3a | Select pids → live payload stream, truncated inspect, per-topic filter |
| **Broadcast Trace** | 3b | "Arm" → next broadcast on topic X renders its fan-out tree with hop timings |
| **Process Inspector** | 4.2 | `:sys` state + message view for one pid |

Browser-side integration with the host app (LiveDebugger's floating button / iframe
trick) is explicitly a non-goal for v1 — the tool is its own tab.

---

## 7. Packaging and dependency strategy

Two-part split, one hex package:

- **Core** (`Wiretap`, `Wiretap.Session`, `Wiretap.Tracer`, `Wiretap.Snapshot`,
  `Wiretap.Collector`, `Wiretap.Probe`) — plain Elixir. Hard deps: `phoenix_pubsub`
  (which is itself Phoenix-free) and `telemetry`. Fully usable headless from iex and
  ExUnit — `Wiretap.Snapshot.topics(TSS.PubSub)` should be a better assertion helper
  than the hand-rolled `Registry.keys/2` our search test uses today.
- **UI** — `phoenix_live_view`, `phoenix`, `bandit` as **optional deps**; every UI
  module wrapped in `if Code.ensure_loaded?(Phoenix.LiveView)`. Host apps install
  `{:wiretap, "~> 0.1", only: :dev}` and get the endpoint; a plain OTP app gets the
  headless core.
- **Minimum versions:** OTP 27 (trace sessions — non-negotiable, see §3 L2), Elixir
  ~> 1.17.

Module layout sketch:

```
lib/
  wiretap.ex                  # public API + docs
  wiretap/application.ex      # supervisor: SessionManager, Wiretap.PubSub, (Endpoint if UI)
  wiretap/session.ex          # session struct, budgets, lifecycle
  wiretap/session_manager.ex  # attach/detach orchestration, teardown guarantees
  wiretap/snapshot.ex         # L1: Registry.select, diffing, pid labeling
  wiretap/tracer.ex           # L2/3a: trace-session ownership, match specs, receiver
  wiretap/seq_tracer.ex       # 3b: system tracer singleton, broadcast-tree assembly
  wiretap/collector.ex        # ETS ring buffer, event normalization
  wiretap/probe.ex            # compile-time-gated tap macro
  wiretap/telemetry_bridge.ex # 4.1
  wiretap/sys_inspector.ex    # 4.2
  wiretap/ui/                 # endpoint, router, live views, components (optional)
  wiretap/dashboard_page.ex   # v0 LiveDashboard page (optional)
```

---

## 8. Safety and footprint principles (the contract)

1. **Idle = free.** No pollers, no trace patterns, no handlers unless a session is
   live. Installing the dep changes nothing at runtime.
2. **Everything attached is budgeted** (events, rate, wall clock) and **everything is
   torn down** on session end/expiry/crash — no orphaned trace flags, monitors, or
   `:sys` hooks, ever.
3. **Trace sessions only; never legacy global tracing.** Coexist with LiveDebugger and
   recon or refuse to start, loudly.
4. **Read-only toward the host.** Wiretap never subscribes to host topics, never sends
   to host processes, never mutates host ETS. (The probe macro is host code and exempt
   by definition.)
5. **Dev-first, prod-possible.** Defaults assume dev. A `config :wiretap, :profile,
   :production` mode tightens budgets ~10×, disables layer 3a payload capture, and
   requires explicit per-session confirmation — recon proves careful tracing is
   prod-viable, but that is opt-in, never default.
6. **Payloads are previews.** Truncated `inspect` only; never store or render full
   terms (they can be huge and they can be sensitive).

---

## 9. Project instantiation

```bash
# 0. Confirm the name is free
open https://hex.pm/packages/wiretap   # and search GitHub for "wiretap elixir"

# 1. Bootstrap the library (supervised: it owns SessionManager + its own PubSub)
mix new wiretap --sup --module Wiretap
cd wiretap
git init && git add -A && git commit -m "mix new wiretap --sup"
gh repo create curtisault/wiretap --private --source=. --push   # flip public at v0.1

# 2. Tooling baseline (mirrors SandDrive conventions)
#    add to mix.exs deps and commit each with its config:
#      {:styler, "~> 1.2", only: [:dev, :test], runtime: false}
#      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
#      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
#      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
mix deps.get && mix format && mix credo && mix dialyzer   # sanity pass

# 3. Core runtime deps
#      {:phoenix_pubsub, "~> 2.1"}
#      {:telemetry, "~> 1.2"}
#    UI deps (optional: true so headless installs stay lean)
#      {:phoenix_live_view, "~> 1.0", optional: true}
#      {:phoenix, "~> 1.7", optional: true}
#      {:bandit, "~> 1.5", optional: true}

# 4. Dev harness — a throwaway Phoenix app *inside* dev/ that uses the library
#    path-dep style (the LiveDebugger repo layout), so the UI is developed against
#    a real host app with real subscriptions:
mkdir dev && cd dev
mix phx.new harness --no-ecto --no-mailer --no-gettext --no-dashboard
#    in dev/harness/mix.exs: {:wiretap, path: "../.."}
#    harness gets a couple of demo LiveViews that subscribe/unsubscribe on mount /
#    button clicks, plus a :timer-driven broadcaster — instant Roll Call content.

# 5. CI (GitHub Actions): format --check-formatted, credo --strict, dialyzer,
#    test matrix pinned to OTP >= 27 / Elixir >= 1.17 (trace sessions gate OTP).

# 6. Hex/publish metadata in mix.exs when ready:
#    description, package: [licenses: ["MIT"], links], docs: [main: "Wiretap"]
mix hex.build   # dry-run packaging before ever publishing
```

Development sequencing note: build `Wiretap.Snapshot` first (pure, trivially testable,
immediately useful in SandDrive's own tests), then the v0 LiveDashboard page against it,
then the Tracer — tracing is the highest-risk component and benefits from the session/
collector scaffolding already existing.

---

## 10. Roadmap

Maintained in [roadmap.md](roadmap.md), which tracks per-release checklists and
status. Sequencing was revised by discovery decision **A2**
([discovery.md](discovery.md) §A2): the telemetry bridge and probe macro ship in
v0.2, ahead of the tracer (v0.3), so the highest-risk component lands into already
hardened session/collector scaffolding.

## 11. Open questions for the implementation-discovery session

1. Registry internals coupling: `Registry.select` shapes and the PubSub registry's
   entry format are semi-private — pin per phoenix_pubsub version, or feature-detect?
2. Trace-session receiver design: one receiver per session vs shared with routing;
   backpressure when the UI is slow.
3. seq_trace singleton arbitration when two users arm Broadcast Trace simultaneously.
4. How much pid labeling is worth: LiveView view/component attribution is cheap;
   full `$callers`/`$ancestors` chains may be noise.
5. Whether the v0 LiveDashboard page survives into v1 or gets retired to cut a
   maintenance surface.
6. Adapter coverage: PG2 adapter only at first? Redis adapter introspection differs.
7. License (MIT assumed) and whether SandDrive dogfoods a path dep before hex publish.
