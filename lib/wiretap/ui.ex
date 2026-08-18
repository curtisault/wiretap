defmodule Wiretap.UI do
  @moduledoc """
  The standalone dev UI (architecture §6 v1): its own endpoint on its own
  port, never touching the host's router, sessions, or auth.

  Opt-in: `config :wiretap, ui: true` (or `[port: 5556, pubsub: MyApp.PubSub]`)
  starts `Wiretap.UI.Endpoint` — but only when the optional UI deps
  (`phoenix`, `phoenix_live_view`, `bandit`) are present; otherwise one loud
  log line and the app boots headless. `:pubsub` names the instance the Roll
  Call panel observes and new sessions default to.
  """

  alias Wiretap.UI.Endpoint

  require Logger

  @default_port 5556

  @doc false
  @spec children() :: [module()]
  def children do
    case Application.get_env(:wiretap, :ui) do
      falsy when falsy in [nil, false] -> []
      true -> configure([])
      conf when is_list(conf) -> configure(conf)
    end
  end

  @doc "The PubSub instance the UI observes (from `config :wiretap, ui: [pubsub: …]`)."
  @spec pubsub() :: atom() | nil
  def pubsub, do: Application.get_env(:wiretap, :ui_pubsub)

  defp configure(conf) do
    if deps_available?() do
      Application.put_env(:wiretap, :ui_pubsub, Keyword.get(conf, :pubsub))

      Application.put_env(
        :wiretap,
        Endpoint,
        endpoint_config(Keyword.get(conf, :port, @default_port))
      )

      [Endpoint]
    else
      Logger.warning(
        "Wiretap: UI is configured but the optional deps (phoenix, " <>
          "phoenix_live_view, bandit) are not all present — UI disabled"
      )

      []
    end
  end

  defp deps_available? do
    Code.ensure_loaded?(Phoenix.Endpoint) and
      Code.ensure_loaded?(Phoenix.LiveView) and
      Code.ensure_loaded?(Bandit.PhoenixAdapter)
  end

  # Anything the host set under config :wiretap, Wiretap.UI.Endpoint wins;
  # these are the batteries-included defaults for a dev tool.
  defp endpoint_config(port) do
    Keyword.merge(
      [
        adapter: Bandit.PhoenixAdapter,
        http: [ip: {127, 0, 0, 1}, port: port],
        server: true,
        secret_key_base: Base.encode64(:crypto.strong_rand_bytes(48)),
        live_view: [signing_salt: Base.encode16(:crypto.strong_rand_bytes(8))],
        pubsub_server: Wiretap.PubSub,
        check_origin: false,
        render_errors: [formats: [html: Wiretap.UI.ErrorHTML], layout: false]
      ],
      Application.get_env(:wiretap, Endpoint, [])
    )
  end
end
