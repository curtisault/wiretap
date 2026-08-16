defmodule HarnessWeb.DocsController do
  use HarnessWeb, :controller

  def how_it_works(conn, _params), do: render(conn, :how_it_works)
end
