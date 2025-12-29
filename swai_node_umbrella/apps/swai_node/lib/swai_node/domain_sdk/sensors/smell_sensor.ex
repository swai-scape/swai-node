defmodule SwaiNode.DomainSDK.Sensors.SmellSensor do
  @moduledoc """
  Smell sensor for detecting local densities.

  Provides awareness of nearby concentrations:
  - Food density (nearby food count)
  - Agent density (nearby agent count)
  - Danger level (placeholder for threats)

  Total: 3 input values
  """

  @behaviour :agent_sensor

  @channels 3
  @smell_radius 5

  @impl :agent_sensor
  def name, do: <<"smell">>

  @impl :agent_sensor
  def input_count, do: @channels

  @impl :agent_sensor
  def read(agent_state, env_state) do
    hex = Map.get(agent_state, :hex, {0, 0})
    food = Map.get(env_state, :food, %{})
    agents = Map.get(env_state, :agents, %{})

    # Food density: nearby food count normalized
    food_density =
      food
      |> Map.keys()
      |> Enum.count(fn fhex -> hex_distance(hex, fhex) <= @smell_radius end)
      |> then(&min(&1 / 10.0, 1.0))

    # Agent density: nearby agents
    agent_density =
      agents
      |> Map.values()
      |> Enum.count(fn a ->
        ahex = Map.get(a, :hex, {0, 0})
        dist = hex_distance(hex, ahex)
        dist <= @smell_radius and dist > 0
      end)
      |> then(&min(&1 / 5.0, 1.0))

    # Danger level: placeholder (could be predator density, etc.)
    danger = 0.0

    [food_density, agent_density, danger]
  end

  defp hex_distance({q1, r1}, {q2, r2}) do
    dq = abs(q1 - q2)
    dr = abs(r1 - r2)
    ds = abs((q1 + r1) - (q2 + r2))
    max(dq, max(dr, ds))
  end
end
