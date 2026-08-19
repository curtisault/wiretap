defmodule Harness.Tower do
  @moduledoc """
  Air-traffic source for the demo: maintains a roster of active flights so
  PubSub topics churn naturally.

  Every 2s each active flight broadcasts a position report on
  `"flight:<callsign>"` carrying full metadata (aircraft type, route, squawk,
  altitude, heading, ground speed, vertical rate). Flights land after 10–20
  ticks; new arrivals appear at random, so the roster fluctuates anywhere
  between #{2} and #{25} flights. Lifecycle events and the roster go to
  `"atc:events"`: `{:roster, [callsign]}`, `{:atc, :entered | :landed, callsign}`.
  """

  use GenServer

  @tick :timer.seconds(2)
  @min_active 2
  @max_active 25
  @seed_active 6
  @ttl_range 10..20
  @types ~w(B737 A320 A220 E175 CRJ9 B788 A359 C172)
  @airports ~w(KJFK KLAX KORD KDEN KSEA KATL KSFO KBOS KAUS KMSY)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Callsigns currently in the airspace, sorted."
  def active_flights, do: GenServer.call(__MODULE__, :active_flights)

  @impl true
  def init(_opts) do
    state = spawn_flights(%{flights: %{}, counter: 100}, @seed_active, announce?: false)
    schedule()
    {:ok, state}
  end

  @impl true
  def handle_call(:active_flights, _from, state), do: {:reply, roster(state), state}

  @impl true
  def handle_info(:tick, state) do
    state =
      state
      |> transmit()
      |> land_expired()
      |> arrivals()

    broadcast("atc:events", {:roster, roster(state)})
    schedule()
    {:noreply, state}
  end

  defp transmit(state) do
    flights =
      Map.new(state.flights, fn {callsign, flight} ->
        payload = %{
          alt: flight.alt,
          hdg: flight.hdg,
          gs: flight.gs,
          vertical_rate: flight.vr,
          squawk: flight.squawk,
          type: flight.type,
          origin: flight.origin,
          destination: flight.destination
        }

        broadcast("flight:" <> callsign, {:position, callsign, payload})

        :telemetry.execute(
          [:harness, :tower, :transmission],
          %{alt: flight.alt, gs: flight.gs},
          %{callsign: callsign, topic: "flight:" <> callsign}
        )

        {callsign,
         %{
           flight
           | alt: max(flight.alt + div(flight.vr * 2, 60), 2_000),
             hdg: Integer.mod(flight.hdg + Enum.random(-8..8), 360),
             gs: clamp(flight.gs + Enum.random(-10..10), 120, 560),
             vr: clamp(flight.vr + Enum.random(-300..300//100), -2_500, 2_500),
             ttl: flight.ttl - 1
         }}
      end)

    %{state | flights: flights}
  end

  defp land_expired(state) do
    {landed, active} =
      Enum.split_with(state.flights, fn {_callsign, flight} -> flight.ttl <= 0 end)

    for {callsign, _flight} <- landed do
      broadcast("atc:events", {:atc, :landed, callsign})
      :telemetry.execute([:harness, :tower, :landed], %{}, %{callsign: callsign})
    end

    %{state | flights: Map.new(active)}
  end

  # The roster fluctuates: backfill to the floor, then random arrivals up to
  # the ceiling so the airspace can swell toward @max_active and thin out again.
  defp arrivals(state) do
    size = map_size(state.flights)

    cond do
      size < @min_active ->
        spawn_flights(state, @min_active - size, announce?: true)

      size < @max_active and :rand.uniform(100) <= 35 ->
        spawn_flights(state, min(Enum.random(1..3), @max_active - size), announce?: true)

      true ->
        state
    end
  end

  defp spawn_flights(state, 0, _opts), do: state

  defp spawn_flights(state, n, opts) do
    callsign = "WT-#{state.counter + 1}"
    [origin, destination] = Enum.take_random(@airports, 2)

    flight = %{
      alt: Enum.random(8..38) * 1_000,
      hdg: Enum.random(0..359),
      gs: Enum.random(380..520),
      vr: Enum.random(-10..10) * 100,
      squawk: Enum.map_join(1..4, "", fn _ -> Enum.random(0..7) end),
      type: Enum.random(@types),
      origin: origin,
      destination: destination,
      ttl: Enum.random(@ttl_range)
    }

    if opts[:announce?] do
      broadcast("atc:events", {:atc, :entered, callsign})

      :telemetry.execute(
        [:harness, :tower, :entered],
        %{},
        %{callsign: callsign, type: flight.type, route: "#{origin} → #{destination}"}
      )
    end

    spawn_flights(
      %{state | flights: Map.put(state.flights, callsign, flight), counter: state.counter + 1},
      n - 1,
      opts
    )
  end

  defp clamp(value, low, high), do: value |> max(low) |> min(high)

  defp roster(state), do: state.flights |> Map.keys() |> Enum.sort()

  defp broadcast(topic, message), do: Phoenix.PubSub.broadcast(Harness.PubSub, topic, message)

  defp schedule, do: Process.send_after(self(), :tick, @tick)
end
