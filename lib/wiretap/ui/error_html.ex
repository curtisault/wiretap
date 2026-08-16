if Code.ensure_loaded?(Phoenix.Controller) do
  defmodule Wiretap.UI.ErrorHTML do
    @moduledoc false

    @doc false
    @spec render(String.t(), map()) :: String.t()
    def render(template, _assigns) do
      Phoenix.Controller.status_message_from_template(template)
    end
  end
end
