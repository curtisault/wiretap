if Code.ensure_loaded?(Phoenix.LiveView.Router) do
  defmodule Wiretap.UI.Router do
    @moduledoc false

    use Phoenix.Router

    import Phoenix.LiveView.Router

    pipeline :browser do
      plug(:accepts, ["html"])
      plug(:fetch_session)
      plug(:fetch_live_flash)
      plug(:protect_from_forgery)
      plug(:put_root_layout, html: {Wiretap.UI.Layouts, :root})
    end

    scope "/", Wiretap.UI do
      pipe_through(:browser)

      live("/", RollCallLive)
      live("/timeline", TimelineLive)
    end
  end
end
