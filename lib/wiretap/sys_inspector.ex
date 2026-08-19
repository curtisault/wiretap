defmodule Wiretap.SysInspector do
  @moduledoc """
  Process Inspector (layer 3, §4.2): read one live OTP process through `:sys` —
  a truncated state preview, full-depth `$ancestors`/`$callers` breadcrumbs
  (discovery A9), and a temporary live message feed.

  Compliance is detected from the pdict **before** any `:sys` call: a blind
  `:sys.install` on a raw pid can only time out (spike P1). Non-OTP pids get
  `{:error, :not_otp_compliant}` instead of a hang.

  The feed is a `:sys` debug fun that forwards system events straight to the
  receiver as `{:wiretap_sys_event, pid, event}` messages. It removes itself
  when the cap is reached or the receiver dies, and `stop_watching/2` removes
  it eagerly — nothing outlives the inspection.
  """

  alias Wiretap.Snapshot

  @sys_timeout 200
  @preview_opts [limit: 50, printable_limit: 1_024]
  @default_max 50

  @typedoc "Everything `peek/1` learns about an OTP-compliant process."
  @type info :: %{
          pid: pid(),
          label: String.t(),
          initial_call: mfa(),
          state_preview: String.t() | nil,
          message_queue_len: non_neg_integer(),
          ancestors: [String.t()],
          callers: [String.t()]
        }

  @doc """
  Reads a live OTP process: `:sys.get_state` preview (truncated, never the
  full term), `$ancestors`/`$callers` chains as labels, queue length.

      Wiretap.peek(pid)
      #=> {:ok, %{label: "LiveView", state_preview: "%{...}", ancestors: [...], ...}}

  Returns `{:error, :not_otp_compliant}` for raw pids (detected without
  touching `:sys`) and `{:error, :not_alive}` for dead ones. A process too
  busy to answer `:sys` within #{@sys_timeout}ms gets a `nil` state preview
  rather than an error — the chains and queue length are still real.
  """
  @spec peek(pid()) :: {:ok, info()} | {:error, :not_alive | :not_otp_compliant}
  def peek(pid) when is_pid(pid) do
    case Process.info(pid, [:dictionary, :message_queue_len]) do
      nil ->
        {:error, :not_alive}

      info ->
        dict = info[:dictionary]

        case List.keyfind(dict, :"$initial_call", 0) do
          nil ->
            {:error, :not_otp_compliant}

          {_, initial_call} ->
            {:ok,
             %{
               pid: pid,
               label: Snapshot.label(pid),
               initial_call: initial_call,
               state_preview: state_preview(pid),
               message_queue_len: info[:message_queue_len],
               ancestors: chain(dict, :"$ancestors"),
               callers: chain(dict, :"$callers")
             }}
        end
    end
  end

  @doc """
  Starts a live message feed: `receiver` gets `{:wiretap_sys_event, pid,
  event}` for each `:sys` system event on `pid` (a single message can fire
  several). The debug fun removes itself after `:max` events (default
  #{@default_max}) or as soon as the receiver is dead — call
  `stop_watching/2` with the returned id to remove it eagerly.
  """
  @spec watch_messages(pid(), pid(), keyword()) ::
          {:ok, reference()} | {:error, :not_alive | :not_otp_compliant | :sys_unresponsive}
  def watch_messages(pid, receiver \\ self(), opts \\ []) when is_pid(pid) and is_pid(receiver) do
    max = Keyword.get(opts, :max, @default_max)

    with {:ok, _info} <- compliant(pid) do
      id = make_ref()
      fun = fn remaining, event, _proc_state -> forward(receiver, pid, event, remaining) end

      try do
        :ok = :sys.install(pid, {{:wiretap, id}, fun, max}, @sys_timeout)
        {:ok, id}
      catch
        :exit, _ -> {:error, :sys_unresponsive}
      end
    end
  end

  @doc "Removes the feed installed by `watch_messages/3`. Always returns `:ok`."
  @spec stop_watching(pid(), reference()) :: :ok
  def stop_watching(pid, id) when is_pid(pid) and is_reference(id) do
    :sys.remove(pid, {:wiretap, id}, @sys_timeout)
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  One-line rendering of a `:sys` system event, previews truncated per §8.6.
  The raw event stays available on the feed message for pattern-matching.
  """
  @spec describe_event(term()) :: String.t()
  def describe_event({:in, msg}), do: "in ◀ " <> preview(msg)
  def describe_event({:in, msg, from}), do: "in ◀ #{preview(msg)} (from #{preview(from)})"
  def describe_event({:out, msg, to}), do: "out ▶ #{preview(msg)} (to #{preview(to)})"
  def describe_event({:out, msg, to, _state}), do: "out ▶ #{preview(msg)} (to #{preview(to)})"
  def describe_event({:noreply, _state}), do: "→ noreply"
  def describe_event(other), do: preview(other)

  # The :sys debug fun body: self-removing (:done) at the cap or on a dead
  # receiver — nothing outlives the inspection.
  defp forward(receiver, pid, event, remaining) when remaining > 0 do
    if Process.alive?(receiver) do
      send(receiver, {:wiretap_sys_event, pid, event})
      remaining - 1
    else
      :done
    end
  end

  defp forward(_receiver, _pid, _event, _remaining), do: :done

  defp compliant(pid) do
    case peek(pid) do
      {:ok, info} -> {:ok, info}
      error -> error
    end
  end

  # Never blindly — peek/1 has already proven the pid speaks :sys protocol.
  defp state_preview(pid) do
    preview(:sys.get_state(pid, @sys_timeout))
  catch
    :exit, _ -> nil
  end

  # $ancestors entries are pids or registered names; $callers are pids.
  # Full depth by design (A9): breadcrumbs live only in this detail pane.
  defp chain(dict, key) do
    case List.keyfind(dict, key, 0) do
      {_, entries} when is_list(entries) -> Enum.map(entries, &chain_label/1)
      _ -> []
    end
  end

  defp chain_label(pid) when is_pid(pid), do: Snapshot.label(pid)
  defp chain_label(name), do: inspect(name)

  defp preview(term), do: inspect(term, @preview_opts)
end
