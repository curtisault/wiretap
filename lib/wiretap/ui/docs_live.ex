if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Wiretap.UI.DocsLive do
    @moduledoc false

    use Phoenix.LiveView

    alias Wiretap.UI.Layouts

    @impl true
    def mount(_params, _session, socket), do: {:ok, socket}

    @impl true
    def render(assigns) do
      ~H"""
      <Layouts.nav active={:docs} />
      <main class="wt-main wt-docs">
        <h1>How wiretap works</h1>
        <p class="wt-dim">
          Wiretap answers three questions about a running BEAM app, live: who is listening
          on your Phoenix.PubSub topics, when did they start and stop (and who asked), and
          what a tapped subscriber is hearing. Your app is never modified and pays nothing
          while the tool is idle.
        </p>

        <section>
          <h2>The flow</h2>
          <pre phx-no-curly-interpolation>
      ┌──────────────────────────────────────────────────────────────────┐
      │ YOUR APP — unmodified; pays nothing while wiretap is idle        │
      │                                                                  │
      │   publishers ─── broadcast ───▶ Phoenix.PubSub (MyApp.PubSub)    │
      │                                      │                           │
      │                                      ▼                           │
      │                           Registry (duplicate-key ETS)           │
      │                           topic ──▶ [subscriber pids]            │
      │                                      ▲                           │
      │   subscribers ── subscribe/unsubscribe ┘                         │
      └───────────────────────────┬──────────────────────────────────────┘
                                  │ registry reads + OTP trace sessions,
                                  │ attached from outside
                                  ▼
      ┌──────────────────────────────────────────────────────────────────┐
      │ WIRETAP                                                          │
      │                                                                  │
      │   Wiretap.Snapshot (layer 1) ── topic → pids, roll_call, diff    │
      │                                                                  │
      │   session without :trace     │    session with trace: true       │
      │         ▼                    │          ▼                        │
      │   Snapshotter                │    Tracer (layer 2)               │
      │     polls + diffs (≈ approx) │      exact events, {:caller}      │
      │     monitors → left_by_death │      attribution, VM-level topic  │
      │         │                    │      filters, monitors            │
      │         └──────────┬─────────┴──────────┘                        │
      │                    ▼                                             │
      │   Collector ── per-session ring buffer (10k), budgets enforced   │
      │                                                                  │
      │   layer 3, on demand: tap: [pid] — what a pid hears (:receive)   │
      │   trace_broadcast/4 — seq_trace fan-out tree · peek/1 — :sys     │
      │                                                                  │
      │   surfaces: this UI · LiveDashboard page · iex · ExUnit helpers  │
      └──────────────────────────────────────────────────────────────────┘
          </pre>
        </section>

        <section>
          <h2>Every panel is a public function</h2>
          <table class="wt-table">
            <thead>
              <tr>
                <th>Panel interaction</th>
                <th>Headless twin</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>Roll Call table / topic tree</td>
                <td>Wiretap.snapshot/1 · Wiretap.Snapshot.roll_call/2</td>
              </tr>
              <tr>
                <td>Timeline stream (text filter is display-only; deep-link with ?q=)</td>
                <td>Wiretap.events/1 (+ watch/2, stop/1, sessions/0); filter twin: |&gt; Enum.filter/2</td>
              </tr>
              <tr>
                <td>Row inspector (click any Timeline row)</td>
                <td>Wiretap.events/1, find by seq — the modal shows the exact expression</td>
              </tr>
              <tr>
                <td>Topic inspector (click any Roll Call topic)</td>
                <td>Wiretap.subscribers/2 + Wiretap.Snapshot.label/1 (cross-topic view from snapshot/1)</td>
              </tr>
              <tr>
                <td>Sessions tab (overview; click a row for its timeline)</td>
                <td>Wiretap.sessions/0</td>
              </tr>
              <tr>
                <td>"tap messages" (topic inspector → subscriber row)</td>
                <td>Wiretap.watch(pubsub, tap: [pid]) — :message events with payload previews</td>
              </tr>
              <tr>
                <td>Broadcast Trace (topic inspector → send + trace)</td>
                <td>Wiretap.trace_broadcast/4 — the stamped delivery tree, relays included</td>
              </tr>
              <tr>
                <td>"inspect" (topic inspector → subscriber row)</td>
                <td>
                  Wiretap.peek/1 · SysInspector.watch_messages/3 · vitals/1 — :sys state, live feed, sampled vitals
                </td>
              </tr>
              <tr>
                <td>Arm form, "trace (exact events)"</td>
                <td>Wiretap.watch(pubsub, trace: true) — or [prefixes: [...], mfas: [...]]</td>
              </tr>
              <tr>
                <td>Subscription assertions in host tests</td>
                <td>Wiretap.Test.assert_subscribed / refute_subscribed / assert_no_subscribers</td>
              </tr>
            </tbody>
          </table>
        </section>

        <section>
          <h2>Sessions, budgets, honesty</h2>
          <p>
            A capture session records events until stopped or a budget expires it. Three
            budgets, all auto-detaching: <b>max_events</b> (default 1000),
            <b>max_duration_ms</b> (default 60s), <b>max_rate</b> (default 250 events/sec).
            Every event carries two axes — <b>kind</b> (what happened) and <b>source</b>
            (how wiretap knows). Snapshot-sourced rows wear the ≈ badge: polling can miss
            sub-interval churn. Trace-sourced rows are exact, caller-attributed, and
            badge-free. Deaths are never calls, so <b>left_by_death</b> (with the exit
            reason) always comes from monitors. Sessions can also <b>tap</b> explicitly
            selected pids (<b>tap: [pid]</b> — layer 3a): everything a tapped pid
            receives lands as a <b>:message</b> event, previewed per the
            <b>payloads:</b> knob (:off | bytes | :unlimited, default 10KB). A
            delivered message carries no topic, so taps are per-pid, never
            per-topic — budgets protect. Finished sessions keep their events
            readable — the ring buffer outlives the session.
          </p>
          <p>
            <b>Broadcast Trace</b> maps one broadcast's full delivery tree with causal
            order and per-hop timings — including second-order hops through relays. It
            is <b>injected by design</b>: a seq token can only be stamped by the sending
            process, so wiretap sends the (test) broadcast itself; organic broadcasts
            cannot be intercepted. One trace at a time node-wide; a foreign seq_trace
            owner is detected and refused. The test broadcast is a <b>real message</b>:
            a subscriber that can't ignore unknown messages (a LiveView without a
            catch-all handle_info) will crash on it — the tree then reports
            "a recipient crashed" and classifies the crash cascade (code loading,
            logging, io) out of the delivery hops.
          </p>
          <p>
            The <b>Process Inspector</b> reads one subscriber through <b>:sys</b>:
            a truncated state preview, full-depth $ancestors/$callers breadcrumbs,
            and a live message feed (capped at 50) via a temporary debug hook —
            removed the moment the pane closes, self-removing if the inspector dies.
            Raw (non-OTP) pids are detected from the pdict <b>before</b> any :sys
            call and refused honestly: they can be tapped, not inspected. The pane
            also shows <b>process vitals</b> (memory, queue length, reductions rate),
            re-sampled on the refresh poll only while the pane is open — never a
            standing emitter — and vitals need no :sys, so even a refused raw pid
            gets them.
          </p>
        </section>

        <section>
          <h2>Wiretap's own telemetry</h2>
          <pre phx-no-curly-interpolation>
      [:wiretap, :session, :start]        span convention; meta lists attachments + budgets
      [:wiretap, :session, :stop]         duration, events_captured; reason manual/expired/crash
      [:wiretap, :budget, :exhausted]     the alarm to page on — which bound, which limit
      [:wiretap, :collector, :dropped]    receiver overload drop count (watermark mode)
      [:wiretap, :registry, :incompatible] shape probe failed; wiretap refuses to guess
          </pre>
        </section>

        <section>
          <h2>Configuration</h2>
          <pre phx-no-curly-interpolation>
      config :wiretap, ui: [port: 5556, pubsub: MyApp.PubSub]  # this UI (dev only)
      config :wiretap, log_file: "wiretap.log"                 # append events to a file (gitignore it)
      config :wiretap, probes: true                            # compile Wiretap.Probe.tap/2 in (host dev.exs)
          </pre>
        </section>

        <section>
          <h2>From iex</h2>
          <pre phx-no-curly-interpolation>
      Wiretap.snapshot(MyApp.PubSub)            # topic → subscriber pids, right now
      Wiretap.subscribers(MyApp.PubSub, "topic")

      {:ok, s} = Wiretap.watch(MyApp.PubSub)                        # ≈ snapshot session
      {:ok, t} = Wiretap.watch(MyApp.PubSub, trace: [prefixes: ["orders:"]])  # exact
      Wiretap.events(t)                         # caller-attributed events
      Wiretap.sessions()
      Wiretap.stop(t)

      pid = Wiretap.subscribers(MyApp.PubSub, "topic") |> hd()
      {:ok, w} = Wiretap.watch(MyApp.PubSub, tap: [pid])     # what that pid hears
      Wiretap.trace_broadcast(MyApp.PubSub, "topic", :ping)  # the fan-out tree
      Wiretap.peek(pid)                         # :sys state + ancestry
          </pre>
        </section>

        <section>
          <h2>The safety contract</h2>
          <ul>
            <li>Idle = free: no pollers, no trace patterns, no handlers unless a session is live.</li>
            <li>Everything attached is budgeted, and everything is torn down on stop, expiry, or crash.</li>
            <li>OTP trace sessions only — never legacy global tracing; coexists with other tools.</li>
            <li>Read-only toward the host: no subscriptions to host topics, no host state mutation.</li>
            <li>Payloads are truncated previews, never full terms.</li>
          </ul>
        </section>
      </main>
      """
    end
  end
end
