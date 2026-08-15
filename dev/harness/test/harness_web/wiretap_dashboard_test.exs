defmodule HarnessWeb.WiretapDashboardTest do
  use HarnessWeb.ConnCase, async: true

  test "the wiretap roll call page renders in LiveDashboard", %{conn: conn} do
    conn = get(conn, "/dashboard/wiretap")
    response = html_response(conn, 200)

    assert response =~ "Roll Call"
    assert response =~ "Harness.PubSub"
  end
end
