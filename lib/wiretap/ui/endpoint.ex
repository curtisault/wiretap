if Code.ensure_loaded?(Phoenix.Endpoint) do
  defmodule Wiretap.UI.Endpoint do
    @moduledoc false

    use Phoenix.Endpoint, otp_app: :wiretap

    socket("/live", Phoenix.LiveView.Socket, websocket: true, longpoll: true)

    plug(Plug.Static, at: "/assets/wiretap", from: {:wiretap, "priv/static"}, gzip: false)

    plug(Plug.Static,
      at: "/assets/phoenix",
      from: {:phoenix, "priv/static"},
      only: ~w(phoenix.min.js)
    )

    plug(Plug.Static,
      at: "/assets/phoenix_live_view",
      from: {:phoenix_live_view, "priv/static"},
      only: ~w(phoenix_live_view.min.js)
    )

    plug(Plug.Session,
      store: :cookie,
      key: "_wiretap_ui",
      signing_salt: "wiretap_ui",
      same_site: "Lax"
    )

    plug(Wiretap.UI.Router)
  end
end
