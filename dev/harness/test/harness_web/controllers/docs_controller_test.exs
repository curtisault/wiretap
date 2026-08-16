defmodule HarnessWeb.DocsControllerTest do
  use HarnessWeb.ConnCase, async: true

  test "GET /docs renders the how-it-works page", %{conn: conn} do
    conn = get(conn, ~p"/docs")
    response = html_response(conn, 200)

    assert response =~ "How Wiretap works"
    assert response =~ "HARNESS — unmodified host app"
    assert response =~ "WIRETAP — the library under demonstration"
    assert response =~ "Wiretap.Snapshot"
    assert response =~ "Reproduce a subscription leak"
  end
end
