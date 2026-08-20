defmodule Wiretap.UITest do
  # The UI endpoint and its :ui_pubsub config are global — keep synchronous.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Wiretap.Snapshot
  alias Wiretap.UI.Endpoint

  @endpoint Endpoint

  defmodule OtpListener do
    @moduledoc false
    use GenServer

    def start(pubsub, topic, state), do: GenServer.start(__MODULE__, {pubsub, topic, state})

    @impl true
    def init({pubsub, topic, state}) do
      :ok = Phoenix.PubSub.subscribe(pubsub, topic)
      {:ok, state}
    end

    @impl true
    def handle_info(_msg, state), do: {:noreply, state}
  end

  setup_all do
    Application.put_env(:wiretap, Endpoint,
      secret_key_base: String.duplicate("a", 64),
      live_view: [signing_salt: "wiretap-test"],
      server: false,
      pubsub_server: Wiretap.PubSub,
      check_origin: false,
      render_errors: [formats: [html: Wiretap.UI.ErrorHTML], layout: false]
    )

    start_supervised!(Endpoint)
    :ok
  end

  setup do
    pubsub = :"pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})
    Application.put_env(:wiretap, :ui_pubsub, pubsub)
    on_exit(fn -> Application.delete_env(:wiretap, :ui_pubsub) end)
    %{conn: build_conn(), pubsub: pubsub}
  end

  defp subscribe(pubsub, topic) do
    parent = self()

    pid =
      spawn(fn ->
        :ok = Phoenix.PubSub.subscribe(pubsub, topic)
        send(parent, {:ready, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:ready, ^pid}
    pid
  end

  defp eventually(fun, tries \\ 100) do
    fun.()
  rescue
    e in [ExUnit.AssertionError] ->
      if tries > 0 do
        Process.sleep(20)
        eventually(fun, tries - 1)
      else
        reraise e, __STACKTRACE__
      end
  end

  defp eventually_value(fun), do: eventually(fun)

  describe "Snapshot.group/2 (headless twin of the Roll Call tree)" do
    test "groups prefixed topics, keeps singletons flat, sorts by subscribers" do
      rows = [
        %{topic: "station:jazz", subscribers: 2, pids: []},
        %{topic: "station:news", subscribers: 1, pids: []},
        %{topic: "lonely", subscribers: 1, pids: []},
        %{topic: "solo:topic", subscribers: 5, pids: []}
      ]

      assert [
               %{label: "solo:topic", prefix: nil, subscribers: 5},
               %{label: "station:*", prefix: "station", subscribers: 3, topics: [_, _]},
               %{label: "lonely", prefix: nil, subscribers: 1}
             ] = Snapshot.group(rows, ":")
    end
  end

  describe "Roll Call panel" do
    test "renders groups with live data, filters, and expands", %{conn: conn, pubsub: pubsub} do
      subscribe(pubsub, "station:jazz")
      subscribe(pubsub, "station:news")
      subscribe(pubsub, "atc:events")

      {:ok, view, html} = live(conn, "/")
      assert html =~ "station:*"
      assert html =~ "atc:events"

      html = view |> element("tr[phx-value-label='station:*']") |> render_click()
      assert html =~ "station:jazz"

      html = view |> element("form") |> render_change(%{"q" => "atc"})
      assert html =~ "atc:events"
      refute html =~ "station:*"

      html = view |> element("form") |> render_change(%{"q" => "nobody-home"})
      assert html =~ "Nobody is listening to"
    end

    test "clicking a topic opens the subscriber inspector with cross-topic view",
         %{conn: conn, pubsub: pubsub} do
      listener = subscribe(pubsub, "station:jazz")
      :ok = Phoenix.PubSub.subscribe(pubsub, "station:jazz")
      :ok = Phoenix.PubSub.subscribe(pubsub, "atc:events")

      {:ok, view, _html} = live(conn, "/")

      html =
        view
        |> element("tr[phx-value-topic='station:jazz']")
        |> render_click()

      assert html =~ "2 subscriber(s)"
      assert html =~ String.replace(inspect(listener), ["<", ">"], &%{"<" => "&lt;", ">" => "&gt;"}[&1])
      # the test process subscribes to both topics: the cross-topic view shows it
      assert html =~ "also subscribed: atc:events"
      assert html =~ ~s(headless twin: Wiretap.subscribers)

      html = view |> element(".wt-modal-box button", "close") |> render_click()
      refute html =~ "headless twin"
    end

    test "tap messages from the topic inspector starts a tapping session",
         %{conn: conn, pubsub: pubsub} do
      listener = subscribe(pubsub, "station:jazz")
      {:ok, view, _html} = live(conn, "/")

      view |> element("tr[phx-value-topic='station:jazz']") |> render_click()
      view |> element("button", "tap messages") |> render_click()

      session =
        Enum.find(Wiretap.sessions(), &(&1.status == :running and &1.tap == [listener]))

      assert session, "expected a running session tapping the subscriber"
      assert_redirect(view, "/timeline?session=#{session.name}")

      Wiretap.stop(session.name)
    end

    test "broadcast trace from the topic inspector renders the delivery tree",
         %{conn: conn, pubsub: pubsub} do
      _listener = subscribe(pubsub, "station:jazz")
      {:ok, view, _html} = live(conn, "/")

      view |> element("tr[phx-value-topic='station:jazz']") |> render_click()

      html =
        view
        |> element("form[phx-submit=trace_broadcast]")
        |> render_submit(%{"payload" => "tree please"})

      assert html =~ "1 deliveries · depth 1"
      assert html =~ "tree please"
      assert html =~ "µs"

      # unwired topic: honest empty answer
      view |> element(".wt-modal-box button", "close") |> render_click()
      view |> element("form") |> render_change(%{"q" => ""})
      :ok = Phoenix.PubSub.subscribe(pubsub, "station:empty-check")
      :ok = Phoenix.PubSub.unsubscribe(pubsub, "station:empty-check")
      Process.sleep(10)
      :ok
    end

    test "inspecting an OTP subscriber shows state, chains, and a live feed",
         %{conn: conn, pubsub: pubsub} do
      {:ok, listener} = OtpListener.start(pubsub, "station:jazz", %{tracks: 3})

      {:ok, view, _html} = live(conn, "/")
      view |> element("tr[phx-value-topic='station:jazz']") |> render_click()

      html = view |> element("button", "inspect") |> render_click()
      assert html =~ "initial call"
      assert html =~ "OtpListener.init/1"
      assert html =~ "tracks: 3"
      assert html =~ "ancestors"
      assert html =~ "headless twin: Wiretap.peek"

      # vitals sample on open; the refresh poll re-samples and adds the delta
      assert html =~ "vitals"
      assert html =~ "reductions"
      send(view.pid, :refresh)
      assert render(view) =~ "/s)"

      # the live feed: a broadcast lands as a :sys event in the open pane
      Phoenix.PubSub.broadcast(pubsub, "station:jazz", {:now_playing, "Take Five"})
      eventually(fn -> assert render(view) =~ "Take Five" end)

      html = view |> element(".wt-inspector button", "close") |> render_click()
      refute html =~ "initial call"

      GenServer.stop(listener)
    end

    test "a raw-spawn subscriber gets the honest :sys refusal",
         %{conn: conn, pubsub: pubsub} do
      subscribe(pubsub, "station:raw")

      {:ok, view, _html} = live(conn, "/")
      view |> element("tr[phx-value-topic='station:raw']") |> render_click()

      html = view |> element("button", "inspect") |> render_click()
      assert html =~ "speak the :sys protocol"
      refute html =~ "initial call"
      # vitals need no :sys — the refused pid still gets them
      assert html =~ "vitals"
    end

    test "empty registry gets the explicit empty state", %{conn: conn, pubsub: pubsub} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Nobody is subscribed to anything on #{inspect(pubsub)}"
    end

    test "a failed shape probe renders the unavailable banner", %{conn: conn} do
      Application.put_env(:wiretap, :ui_pubsub, :no_such_registry)
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Layer 1 unavailable"
      assert html =~ "no_registry"
    end
  end

  describe "session list freshness" do
    test "a session started elsewhere appears in an already-open Timeline",
         %{conn: conn, pubsub: pubsub} do
      {:ok, view, _html} = live(conn, "/timeline")

      # started from anywhere else on the node (e.g. the harness demo card)
      {:ok, session} = Wiretap.watch(pubsub, trace: true)

      eventually(fn -> assert render(view) =~ session end)

      Wiretap.stop(session)
    end
  end

  describe "Sessions tab" do
    test "lists every session with status and mode; a row opens its timeline",
         %{conn: conn, pubsub: pubsub} do
      {:ok, traced} = Wiretap.watch(pubsub, trace: true)
      {:ok, plain} = Wiretap.watch(pubsub)
      :ok = Wiretap.stop(plain)

      {:ok, view, html} = live(conn, "/sessions")

      assert html =~ traced
      assert html =~ plain
      assert html =~ "exact"
      assert html =~ "≈ snapshot"
      assert html =~ "stopped"
      assert html =~ "headless twin: Wiretap.sessions()"

      view
      |> element("tr[phx-value-session='#{traced}']")
      |> render_click()

      assert_redirect(view, "/timeline?session=#{traced}")

      Wiretap.stop(traced)
    end
  end

  describe "Docs panel" do
    test "renders the host-agnostic library docs", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/docs")

      assert html =~ "How wiretap works"
      assert html =~ "YOUR APP — unmodified"
      assert html =~ "Every panel is a public function"
      assert html =~ "Wiretap.peek/1"
      assert html =~ "max_rate"
      assert html =~ "The safety contract"
    end
  end

  describe "Timeline panel" do
    test "streams a session's events with honesty markers and controls",
         %{conn: conn, pubsub: pubsub} do
      {:ok, session} = Wiretap.watch(pubsub, interval_ms: 25)
      listener = subscribe(pubsub, "station:jazz")

      eventually(fn ->
        assert Enum.any?(Wiretap.events(session), &(&1.kind == :joined and &1.pid == listener))
      end)

      {:ok, view, html} = live(conn, "/timeline?session=#{session}")
      assert html =~ session
      assert html =~ "resolution ≈ 25ms"
      assert html =~ "station:jazz"
      # snapshot-sourced rows carry the approximation badge
      assert html =~ "wt-approx"

      html = view |> element("button", "stop") |> render_click()
      assert html =~ "stopped"
    end

    test "the text filter narrows the display without touching capture, and ?q= seeds it",
         %{conn: conn, pubsub: pubsub} do
      {:ok, session} = Wiretap.watch(pubsub, trace: true)
      jazz = subscribe(pubsub, "station:jazz")
      subscribe(pubsub, "atc:events")

      eventually(fn ->
        topics = session |> Wiretap.events() |> Enum.map(& &1.topic)
        assert "station:jazz" in topics and "atc:events" in topics
      end)

      {:ok, view, _html} = live(conn, "/timeline?session=#{session}")

      html = view |> element("#wt-timeline-filter") |> render_change(%{"q" => "jazz"})
      assert html =~ "station:jazz"
      refute html =~ "atc:events"
      assert html =~ "of 2 shown"

      # the full capture is still inspectable by seq while filtered
      joined = Enum.find(Wiretap.events(session), &(&1.topic == "station:jazz"))
      assert joined.pid == jazz

      # no match: explicit empty state with a clear affordance
      html = view |> element("#wt-timeline-filter") |> render_change(%{"q" => "nothing-here"})
      assert html =~ "Nothing matches"
      html = view |> element("button", "clear filter") |> render_click()
      assert html =~ "atc:events"

      # ?q= deep-links a filter
      {:ok, _view, html} = live(conn, "/timeline?session=#{session}&q=jazz")
      assert html =~ "station:jazz"
      refute html =~ "atc:events"

      Wiretap.stop(session)
    end

    test "a tap session's bar states the per-pid honesty note", %{conn: conn, pubsub: pubsub} do
      listener = subscribe(pubsub, "station:jazz")
      {:ok, session} = Wiretap.watch(pubsub, tap: [listener])

      {:ok, _view, html} = live(conn, "/timeline?session=#{session}")
      assert html =~ "delivered messages carry no topic"

      Wiretap.stop(session)
    end

    test "clicking a row opens the full-event inspector", %{conn: conn, pubsub: pubsub} do
      {:ok, session} = Wiretap.watch(pubsub, trace: true)
      listener = subscribe(pubsub, "station:jazz")

      joined =
        eventually_value(fn ->
          event =
            Enum.find(Wiretap.events(session), &(&1.kind == :joined and &1.pid == listener))

          assert event
          event
        end)

      {:ok, view, _html} = live(conn, "/timeline?session=#{session}")

      html =
        view
        |> element(".wt-row[phx-value-seq='#{joined.seq}']")
        |> render_click()

      assert html =~ "event ##{joined.seq} — joined"
      assert html =~ "station:jazz"
      assert html =~ "caller:"
      # pids render HTML-escaped
      assert html =~ String.replace(inspect(listener), ["<", ">"], &%{"<" => "&lt;", ">" => "&gt;"}[&1])
      assert html =~ "headless twin"

      html = view |> element(".wt-modal-box button", "close") |> render_click()
      refute html =~ "headless twin"

      Wiretap.stop(session)
    end

    test "the arm form previews attachments and starts a plain session",
         %{conn: conn, pubsub: pubsub} do
      {:ok, view, html} = live(conn, "/timeline")
      assert html =~ "snapshot polling (~1s, approximate)"

      view |> element("form.wt-arm") |> render_submit()

      session = Enum.find(Wiretap.sessions(), &(&1.pubsub == pubsub and &1.status == :running))
      assert session
      assert session.trace == false

      Wiretap.stop(session.name)
    end

    test "arming with trace shows the exact-events preview and traces the session",
         %{conn: conn, pubsub: pubsub} do
      {:ok, view, _html} = live(conn, "/timeline")

      html =
        view
        |> element("form.wt-arm")
        |> render_change(%{"trace" => "on", "prefixes" => "station:"})

      assert html =~ "call tracing on Phoenix.PubSub.subscribe/2,3"
      assert html =~ "prefixes station:"

      html = view |> element("form.wt-arm") |> render_submit()
      assert html =~ "exact: call tracing armed"

      session = Enum.find(Wiretap.sessions(), &(&1.pubsub == pubsub and &1.status == :running))
      assert session.trace == %{prefixes: ["station:"], mfas: []}

      Wiretap.stop(session.name)
    end
  end
end
