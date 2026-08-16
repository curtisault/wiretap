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
          on your Phoenix.PubSub topics, when did they start and stop (and who asked), and —
          in a later release — what they are hearing. Your app is never modified and pays
          nothing while the tool is idle.
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
                <td>Timeline stream</td>
                <td>Wiretap.events/1 (+ watch/2, stop/1, sessions/0)</td>
              </tr>
              <tr>
                <td>Row inspector (click any Timeline row)</td>
                <td>Wiretap.events/1, find by seq — the modal shows the exact expression</td>
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
            reason) always comes from monitors. Finished sessions keep their events
            readable — the ring buffer outlives the session.
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
      config :wiretap, ui: [port: 4008, pubsub: MyApp.PubSub]  # this UI (dev only)
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
