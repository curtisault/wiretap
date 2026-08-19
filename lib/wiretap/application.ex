defmodule Wiretap.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :unique, name: Wiretap.Registry},
        {Phoenix.PubSub, name: Wiretap.PubSub},
        {DynamicSupervisor, name: Wiretap.SessionSupervisor, strategy: :one_for_one},
        Wiretap.SessionManager,
        Wiretap.SeqTracer
      ] ++ Wiretap.UI.children()

    # Idle = free (§8.1): nothing here polls, traces, or subscribes to host
    # topics. Pollers exist only while a session is running.
    Supervisor.start_link(children, strategy: :one_for_one, name: Wiretap.Supervisor)
  end
end
