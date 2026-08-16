if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Wiretap.UI.Layouts do
    @moduledoc false

    use Phoenix.Component

    @doc false
    def root(assigns) do
      ~H"""
      <!DOCTYPE html>
      <html lang="en">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
          <title>Wiretap</title>
          <link rel="stylesheet" href="/assets/wiretap/wiretap.css" />
          <script>
            (() => {
              const saved = localStorage.getItem("wiretap:theme");
              if (saved) document.documentElement.dataset.theme = saved;
            })();
          </script>
          <script defer src="/assets/phoenix/phoenix.min.js">
          </script>
          <script defer src="/assets/phoenix_live_view/phoenix_live_view.min.js">
          </script>
          <script defer src="/assets/wiretap/wiretap.js">
          </script>
        </head>
        <body>
          {@inner_content}
        </body>
      </html>
      """
    end

    attr(:active, :atom, required: true)

    @doc false
    def nav(assigns) do
      ~H"""
      <header class="wt-nav">
        <span class="wt-brand">⏚ wiretap</span>
        <nav>
          <.link navigate="/" class={@active == :roll_call && "active"}>Roll Call</.link>
          <.link navigate="/timeline" class={@active == :timeline && "active"}>Timeline</.link>
          <.link navigate="/sessions" class={@active == :sessions && "active"}>Sessions</.link>
          <.link navigate="/docs" class={@active == :docs && "active"}>Docs</.link>
        </nav>
        <button class="wt-theme" title="toggle theme" onclick="wiretapToggleTheme()">◐</button>
      </header>
      """
    end

    attr(:title, :string, required: true)
    attr(:body, :string, required: true)
    slot(:action)

    @doc false
    def empty_state(assigns) do
      ~H"""
      <div class="wt-empty">
        <p class="wt-empty-title">{@title}</p>
        <p class="wt-empty-body">{@body}</p>
        {render_slot(@action)}
      </div>
      """
    end
  end
end
