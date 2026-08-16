defmodule Wiretap.TelemetryBridge do
  @moduledoc """
  Bridges host telemetry events into a session's timeline (§4.1).

  Sessions opt in per event name: `Wiretap.watch(pubsub, telemetry:
  [[:my_app, :repo, :query]])`. One handler is attached per session and
  detached at teardown. Bridged events count toward the session's event
  budget like everything else, and carry previews only (§8.6).

  A handler that raises is detached by telemetry itself — it cannot hurt
  the host.
  """

  alias Wiretap.Collector
  alias Wiretap.Session

  @doc "Attaches the session's telemetry handler (no-op when nothing was requested)."
  @spec attach(Session.t()) :: :ok
  def attach(%Session{telemetry: []}), do: :ok

  def attach(%Session{} = session) do
    :telemetry.attach_many(
      handler_id(session.name),
      session.telemetry,
      &__MODULE__.handle_event/4,
      %{session: session.name}
    )
  end

  @doc "Detaches the session's handler. Safe to call when none was attached."
  @spec detach(String.t()) :: :ok
  def detach(session_name) do
    _ = :telemetry.detach(handler_id(session_name))
    :ok
  end

  @doc "Validates the `:telemetry` option: a list of telemetry event names."
  @spec validate(term()) :: :ok | {:error, :invalid_telemetry_option}
  def validate(events) when is_list(events) do
    if Enum.all?(events, fn e -> is_list(e) and e != [] and Enum.all?(e, &is_atom/1) end) do
      :ok
    else
      {:error, :invalid_telemetry_option}
    end
  end

  def validate(_other), do: {:error, :invalid_telemetry_option}

  @doc false
  def handle_event(event, measurements, metadata, %{session: session}) do
    Collector.push(session, %{
      kind: :telemetry,
      source: :telemetry,
      payload_preview: preview(measurements),
      meta: %{event: event, metadata_preview: preview(metadata)}
    })
  end

  defp handler_id(session_name), do: "wiretap-" <> session_name

  defp preview(term), do: inspect(term, limit: 5, printable_limit: 128)
end
