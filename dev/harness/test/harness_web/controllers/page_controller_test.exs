defmodule HarnessWeb.PageControllerTest do
  use HarnessWeb.ConnCase, async: true

  test "GET / renders the demo launcher", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ "Wiretap harness"
    assert response =~ "ATC console"
    assert response =~ "/dashboard/wiretap"
    assert response =~ "/docs"
  end
end
