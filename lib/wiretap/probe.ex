defmodule Wiretap.Probe do
  @moduledoc """
  Opt-in, compile-time-gated probe (§4.4): in-band context for the rare case
  where it beats external attachment.

      require Wiretap.Probe
      Wiretap.Probe.tap("station:\#{id}", label: "modal open", meta: %{user: user.id})

  Enabled only when the **host** compiles with `config :wiretap, probes: true`
  — explicit opt-in, never implicit by Mix env (recompile after toggling; the
  config read is registered as a compile-time dependency). Disabled, the call
  compiles to literal `:ok`: zero footprint, safe to commit.

  When enabled, a probe hit is pushed to every running capture session as a
  `kind: :probe` event, interleaved with everything else on the timeline.
  """

  alias Wiretap.Collector

  @doc """
  Records a probe hit on `topic`. Options: `:label` (short string shown on
  the timeline), `:meta` (map of extra context).
  """
  defmacro tap(topic, opts \\ []) do
    if Application.compile_env(__CALLER__, :wiretap, :probes, false) do
      quote do
        Wiretap.Probe.__emit__(unquote(topic), unquote(opts))
      end
    else
      :ok
    end
  end

  @doc false
  def __emit__(topic, opts) do
    if :ets.whereis(:wiretap_sessions) != :undefined do
      for session <- Wiretap.SessionManager.sessions(), session.status == :running do
        Collector.push(session.name, %{
          kind: :probe,
          source: :probe,
          topic: topic,
          pid: self(),
          meta: %{label: opts[:label], meta: Keyword.get(opts, :meta, %{})}
        })
      end
    end

    :ok
  end
end
