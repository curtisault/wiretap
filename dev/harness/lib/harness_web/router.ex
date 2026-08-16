defmodule HarnessWeb.Router do
  use HarnessWeb, :router

  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HarnessWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", HarnessWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/demo", DemoLive

    live_dashboard "/dashboard",
      additional_pages: [wiretap: {Wiretap.DashboardPage, pubsub: Harness.PubSub}]
  end

  # Other scopes may use custom stacks.
  # scope "/api", HarnessWeb do
  #   pipe_through :api
  # end
end
