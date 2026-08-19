# Loaded automatically when IEx starts in this directory:
#
#     iex -S mix phx.server
#
# Plain `mix phx.server` never reads this file — start with iex to get the
# banner, aliases, and bindings below.

alias Harness.Tower
alias Wiretap.Snapshot

# The real configured ports (not hardcoded) — stays true if config changes.
harness_port =
  get_in(Application.get_env(:harness, HarnessWeb.Endpoint, []), [:http, :port]) || 5555

wiretap_port =
  :wiretap |> Application.get_env(:ui, []) |> Keyword.get(:port, 5556)

IO.puts(
  IO.ANSI.format([
    :green,
    """

    ── wiretap dev harness ──────────────────────────────────────────
    """,
    :light_green,
    """
      ATC console        http://localhost:#{harness_port}/demo
      harness docs       http://localhost:#{harness_port}/docs
      LiveDashboard      http://localhost:#{harness_port}/dashboard/wiretap
      Wiretap UI         http://localhost:#{wiretap_port}          Roll Call
                         http://localhost:#{wiretap_port}/timeline · /sessions · /docs
    """,
    :green,
    """
    ─────────────────────────────────────────────────────────────────
    """,
    :reset,
    """
      aliases   Tower, Snapshot        binding   pubsub = Harness.PubSub

      Wiretap.snapshot(pubsub)                  # topic → subscriber pids
      {:ok, s} = Wiretap.watch(pubsub, trace: true)
      Wiretap.events(s)                         # exact, caller-attributed
      pid = Wiretap.subscribers(pubsub, "atc:events") |> hd()
      {:ok, w} = Wiretap.watch(pubsub, tap: [pid])   # what that pid hears
      Wiretap.trace_broadcast(pubsub, "atc:events", :ping)  # fan-out tree
      Wiretap.peek(pid)                         # :sys state + ancestry
    """
  ])
)

pubsub = Harness.PubSub
