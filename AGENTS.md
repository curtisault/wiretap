# Wiretap — Agent Guide

Wiretap is a planned open-source Elixir library for live `Phoenix.PubSub` introspection:
who is subscribed to which topics (Roll Call), subscription lifecycle as events
(Timeline), actual message payloads (Wiretap panel), and broadcast fan-out trees
(Broadcast Trace). `Phoenix.PubSub` emits no telemetry, so this works via Registry
introspection and OTP 27+ trace sessions instead.

**Current state:** freshly bootstrapped `mix new wiretap --sup` scaffold. The design
lives in `docs/`; almost none of it is implemented yet. Read the docs before writing
code.

## Document map (read in this order)

| File | Role |
|---|---|
| `docs/architecture.md` | The design: three attachment layers, event pipeline, UI strategy, packaging, safety contract (§8) |
| `docs/discovery.md` | Open questions (IDs like A1, B2, C3), verified facts (§0), **decision log (§D)**, spike queue (§E) |
| `docs/roadmap.md` | Source of truth for sequencing — per-release checklists with status. Supersedes architecture.md §10 |

## Workflow conventions

- **Roadmap tracking:** when you complete a roadmap item, tick its checkbox in
  `docs/roadmap.md` and update the release's status emoji in the status table.
- **Decisions:** when an open question from `docs/discovery.md` gets answered, record
  it in the decision log (§D) with date and question ID. Don't relitigate logged
  decisions.
- **Sequencing:** follow the roadmap order. Notably, the telemetry bridge ships in
  v0.2 *before* the tracer (v0.3) — decision A2. Don't build tracing early.

## Commands

```bash
mix test            # run tests
mix format          # format (config: .formatter.exs)
mix compile --warnings-as-errors
```

Planned but **not yet installed** (roadmap v0.0): styler, credo `--strict`, dialyxir,
sobelow, mix_audit, ex_doc, doctor, excoveralls, with `ex_check` (`mix check`) as the
single entry point. Once added, run `mix check` before considering work done.

## Design contracts (non-negotiable, from architecture.md §8)

1. **Idle = free.** No pollers, trace patterns, or handlers unless a session is live.
2. **Everything attached is budgeted** (events, rate, wall clock) and **everything is
   torn down** on session end/expiry/crash. Sessions never auto-resume.
3. **OTP 27+ trace sessions only** — never legacy `:dbg`/`:erlang.trace` globals.
4. **Read-only toward the host app.** Never subscribe to host topics, send to host
   processes, or mutate host ETS. Wiretap has its own `Wiretap.PubSub` for UI updates.
5. **Payloads are truncated previews** — never store or render full terms.

## Version floors

- **OTP 27** (trace sessions gate this) / **Elixir 1.17** — the generated `mix.exs`
  currently says `elixir: "~> 1.19"`, which needs loosening to `~> 1.17` before
  publish (roadmap v0.0).
- CI matrix (once set up): OTP 27/28/29 × Elixir 1.17–1.19.

## Layout (target, from architecture.md §7)

```
lib/wiretap/
  session.ex, session_manager.ex   # lifecycle, budgets, teardown guarantees
  snapshot.ex                      # L1: Registry.select, diffing, pid labeling
  tracer.ex                        # L2/3a: trace sessions, match specs
  seq_tracer.ex                    # 3b: broadcast fan-out
  collector.ex                     # ETS ring buffer, %Wiretap.Event{} normalization
  probe.ex, telemetry_bridge.ex, sys_inspector.ex
  ui/                              # optional: endpoint on :4008, LiveView panels
dev/harness/                       # throwaway Phoenix app, path-deps wiretap (v0.0)
```

UI deps (`phoenix_live_view`, `phoenix`, `bandit`) are `optional: true`; every UI
module is gated with `Code.ensure_loaded?(Phoenix.LiveView)`. The headless core must
stay fully usable from iex and ExUnit.

<!-- gitbutler-agent-setup:start -->
## Version control

- Use GitButler (`but`) for version-control inspection and write operations, including status, diffs, branching, committing, pushing, and history edits.
- Assume multiple agents may be working in this repository. Do not move, amend, squash, discard, commit, push, or otherwise modify another agent's work unless the user asks.
- For commit just/only/specific changes on a new branch (selected-change requests), use the two-command fast path from the GitButler skill: `but diff`, then `but commit -b <branch> -m "message" <id> <id>`.
- For that fast path, after the commit succeeds, stop and summarize; do not run separate branch, staging, status, or diff commands unless the commit output is missing information you need.
- Use the installed GitButler skill for command recipes and syntax before guessing flags, using `--help`, or translating Git habits directly.
- Mutation commands report their result without appending workspace status. Add `--status-after` only when the next step needs resulting workspace IDs or details; otherwise do not rerun status or diff to verify success.
- Use a dedicated GitButler branch for each agent session, unless the user asks for a different branch structure. Commit only changes that belong to that session.
- Do not push or open pull requests unless the user asks.
- Keep commit messages and pull request descriptions succinct: explain what changed, why it changed, and any important decision.

### Amend local fixes into the right commits

- For small cleanup or follow-up fixes, amend an unpublished local commit when the change clearly belongs with that commit's intent.
- Do not create tiny fixup commits unless the user asks.
- Use GitButler to move the relevant changes into the commit where they belong.
- Ask before rewriting pushed, reviewed, shared, or ambiguous history.

### Split unrelated changes into separate commits

- If one file contains unrelated changes, split them by hunk instead of committing the whole file.
- Keep tests with the behavior they verify.
- Split generated output, docs-only edits, or mechanical cleanup into separate commits when each commit remains coherent on its own.
- If the split is ambiguous, summarize the options before committing.

### Create stacked pull requests

- If this session depends on another in-flight branch, stack its branch on top of that dependency instead of mixing the changes.
- If this session is working in a stack, put commits on the branch where they belong.
- Ask before moving commits onto lower, pushed, reviewed, or shared branches.
- Use `but move` for branch stacking and restacking. Do not recreate branches to simulate stacking.
- For stacked branches, create pull requests with `but pr`, not `gh`, so GitButler keeps the right PR base branches and stack metadata.

### Open draft pull requests by default

- When asked to open a pull request, create it as a draft with GitButler unless the user says it is ready for review.
- Remember that creating a draft pull request still publishes the branch.

### Publish on a shortcut phrase

- When the user says `ship`, commit this session's changes on its dedicated GitButler branch, creating one if needed.
- Push the branch and open or update its pull request with GitButler.
- Reuse the existing branch or pull request for this session when one already exists.
- Treat this phrase as approval to commit, push, and open or update a pull request without asking again, unless something risky or surprising changed.

### Branch naming

- When creating a GitButler branch for an agent session, use `'<type>/<month-year-shorthand>-<name>-<short-description>'`.

### Commit message convention

- Follow the `type(scope): summary` commit-message convention when writing commit messages.
<!-- gitbutler-agent-setup:end -->
