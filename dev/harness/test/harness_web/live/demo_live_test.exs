defmodule HarnessWeb.DemoLiveTest do
  use HarnessWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Wiretap.Test

  @pubsub Harness.PubSub

  setup %{conn: conn} do
    {:ok, view, _html} = live(conn, "/demo")
    # flights live 20-40s, so callsigns picked here are stable for the test
    [flight_a, flight_b | _] = Harness.Tower.active_flights()
    %{view: view, flight_a: flight_a, flight_b: flight_b}
  end

  defp track(view, callsign) do
    view |> element("li[phx-value-callsign='#{callsign}']") |> render_click()
  end

  test "tracking multiple flights holds multiple subscriptions at once",
       %{view: view, flight_a: a, flight_b: b} do
    track(view, a)
    track(view, b)

    assert_subscribed(@pubsub, "flight:" <> a, view.pid)
    assert_subscribed(@pubsub, "flight:" <> b, view.pid)
  end

  test "clicking a tracked flight again unsubscribes only that flight",
       %{view: view, flight_a: a, flight_b: b} do
    track(view, a)
    track(view, b)
    track(view, a)

    refute_subscribed(@pubsub, "flight:" <> a, view.pid)
    assert_subscribed(@pubsub, "flight:" <> b, view.pid)
  end

  test "hand off all unsubscribes everything except the steady-state topic",
       %{view: view, flight_a: a, flight_b: b} do
    track(view, a)
    track(view, b)
    view |> element("button", "hand off all") |> render_click()

    refute_subscribed(@pubsub, "flight:" <> a, view.pid)
    refute_subscribed(@pubsub, "flight:" <> b, view.pid)
    assert_subscribed(@pubsub, "atc:events", view.pid)
  end

  test "walking off shift leaks every tracked flight — the bug class Wiretap catches",
       %{view: view, flight_a: a, flight_b: b} do
    track(view, a)
    track(view, b)
    html = view |> element("button", "walk off shift (leaky)") |> render_click()

    # the UI claims the scope is empty…
    refute html =~ "Your scope"
    assert html =~ "subscriptions leaked so far: <span class=\"font-mono\">2</span>"
    # …but the registry knows better
    assert_subscribed(@pubsub, "flight:" <> a, view.pid)
    assert_subscribed(@pubsub, "flight:" <> b, view.pid)
  end

  test "the LiveView subscribes to atc events on mount", %{view: view} do
    assert_subscribed(@pubsub, "atc:events", view.pid)
  end

  test "unknown messages on shared frequencies never crash the console", %{view: view} do
    # wiretap's Broadcast Trace test message, Transmit traffic, future tower shapes
    Phoenix.PubSub.broadcast(@pubsub, "atc:events", {:wiretap_trace, "wiretap test"})
    Phoenix.PubSub.broadcast(@pubsub, "atc:events", {:burst, 1, 500})

    assert render(view) =~ "Airspace"
    assert Process.alive?(view.pid)
  end

  test "clicking a received transmission opens a metadata modal", %{view: view} do
    payload = %{
      alt: 33_000,
      hdg: 210,
      gs: 450,
      vertical_rate: -300,
      squawk: "4021",
      type: "A320",
      origin: "KAUS",
      destination: "KSEA"
    }

    send(view.pid, {:position, "WT-999", payload})
    render(view)

    view |> element("li[phx-click='inspect']", "WT-999") |> render_click()
    html = render(view)

    assert html =~ "WT-999 — transmission"
    assert html =~ "KAUS → KSEA"
    assert html =~ "squawk: 4021"
    assert html =~ "leaked delivery"

    view |> element(".modal-action button", "close") |> render_click()
    refute render(view) =~ "WT-999 — transmission"
  end

  test "the sessions card starts a traced session by default, shows it, and stops it",
       %{view: view, flight_a: a} do
    html = view |> element("form[phx-submit=start_session]") |> render_submit()
    assert html =~ "badge-success"
    assert html =~ "exact"

    session =
      Enum.find(Wiretap.sessions(), &(&1.status == :running and &1.pubsub == Harness.PubSub))

    assert session, "expected a running session watching Harness.PubSub"
    assert session.trace == %{prefixes: [], mfas: []}

    # session observes from outside: it never subscribes to host topics
    refute html =~ ~r/Registry truth.*wiretap/s

    # generate an event the session can capture, then verify it recorded it
    # exactly: source :trace with a caller MFA, not a snapshot approximation
    track(view, a)

    eventually(fn ->
      assert Enum.any?(
               Wiretap.events(session.name),
               &(&1.kind == :joined and &1.source == :trace and match?({_, _, _}, &1.meta.caller))
             )
    end)

    view
    |> element("button[phx-value-session='#{session.name}']")
    |> render_click()

    assert Enum.find(Wiretap.sessions(), &(&1.name == session.name)).status == :stopped
  end

  defp eventually(fun, tries \\ 50) do
    fun.()
  rescue
    e in [ExUnit.AssertionError] ->
      if tries > 0 do
        Process.sleep(50)
        eventually(fun, tries - 1)
      else
        reraise e, __STACKTRACE__
      end
  end
end
