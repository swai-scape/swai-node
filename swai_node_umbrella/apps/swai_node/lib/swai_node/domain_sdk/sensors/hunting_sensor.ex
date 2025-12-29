defmodule SwaiNode.DomainSDK.Sensors.HuntingSensor do
  @moduledoc """
  Hunting sensor for predators - detects and tracks prey.

  Provides 6 inputs about the nearest prey:
  1. Prey detected (0.0 or 1.0)
  2. Relative direction (normalized angle, -1.0 to 1.0)
  3. Distance (normalized, 0.0 = adjacent, 1.0 = max range)
  4. Prey energy level (normalized)
  5. Prey movement direction (relative to predator)
  6. Prey speed (normalized)

  This allows predators to:
  - Locate prey in their hunting range
  - Predict prey movement for interception
  - Prioritize weak/slow targets
  """

  @behaviour :agent_sensor

  @max_hunt_range 10

  @impl :agent_sensor
  def name, do: <<"hunting">>

  @impl :agent_sensor
  def input_count, do: 6

  @impl :agent_sensor
  def read(agent_state, env_state) do
    my_hex = Map.get(agent_state, :hex, {0, 0})
    my_species = Map.get(agent_state, :species, :predator)
    agents = Map.get(env_state, :agents, %{})

    # Find nearest prey (agents of different species)
    prey_list =
      agents
      |> Map.values()
      |> Enum.filter(fn agent ->
        agent_species = Map.get(agent, :species, :forager)
        agent_species != my_species and agent_species != :predator
      end)
      |> Enum.map(fn prey ->
        prey_hex = Map.get(prey, :hex, {0, 0})
        distance = hex_distance(my_hex, prey_hex)
        {prey, distance}
      end)
      |> Enum.filter(fn {_prey, dist} -> dist <= @max_hunt_range end)
      |> Enum.sort_by(fn {_prey, dist} -> dist end)

    case prey_list do
      [] ->
        # No prey detected
        [0.0, 0.0, 1.0, 0.0, 0.0, 0.0]

      [{prey, distance} | _] ->
        prey_hex = Map.get(prey, :hex, {0, 0})
        prey_energy = Map.get(prey, :energy, 100.0) / 300.0
        prey_last_dir = Map.get(prey, :last_direction, 6)
        prey_speed = if prey_last_dir == 6, do: 0.0, else: 1.0

        # Calculate relative direction
        direction = calculate_direction(my_hex, prey_hex)

        # Calculate prey movement relative to us
        prey_movement = calculate_prey_movement(prey_last_dir, direction)

        [
          1.0,  # Prey detected
          direction,
          distance / @max_hunt_range,
          min(prey_energy, 1.0),
          prey_movement,
          prey_speed
        ]
    end
  end

  defp hex_distance({q1, r1}, {q2, r2}) do
    dq = abs(q1 - q2)
    dr = abs(r1 - r2)
    ds = abs(-q1 - r1 - (-q2 - r2))
    max(max(dq, dr), ds)
  end

  defp calculate_direction({q1, r1}, {q2, r2}) do
    # Simplified direction as angle normalized to -1..1
    dq = q2 - q1
    dr = r2 - r1
    angle = :math.atan2(dr, dq)
    angle / :math.pi()
  end

  defp calculate_prey_movement(prey_dir, _our_direction) when prey_dir == 6 do
    0.0  # Prey stationary
  end

  defp calculate_prey_movement(prey_dir, our_direction) do
    # Simplified: positive = moving toward us, negative = away
    prey_angle = prey_dir / 6.0 * 2.0 - 1.0
    diff = abs(prey_angle - our_direction)
    if diff > 0.5, do: 1.0, else: -1.0
  end
end
