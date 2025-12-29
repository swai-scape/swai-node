defmodule SwaiNode.DomainSDK.Sensors.ProprioceptionSensor do
  @moduledoc """
  Proprioception sensor - awareness of own body state.

  Provides 3 inputs about the agent's own physical state:
  1. Current speed (0.0 = stationary, 1.0 = sprinting)
  2. Last heading direction (normalized -1.0 to 1.0)
  3. Stamina (energy available for sprint/attack)

  This allows predators to:
  - Know when they're moving vs stationary
  - Track their own heading for pursuit
  - Manage energy for attacks
  """

  # Implements :agent_sensor behaviour (Erlang)

  def name, do: <<"proprioception">>

  def input_count, do: 3

  def read(agent_state, _env_state) do
    last_direction = Map.get(agent_state, :last_direction, nil)
    energy = Map.get(agent_state, :energy, 100.0) || 100.0
    max_energy = Map.get(agent_state, :max_energy, 400.0) || 400.0
    sprinting = Map.get(agent_state, :sprinting, false)

    # Speed: 0 if stationary, 1 if moving, 2 if sprinting
    speed = cond do
      sprinting -> 1.0
      is_nil(last_direction) or last_direction == 6 -> 0.0
      true -> 0.5
    end

    # Heading: normalized direction
    heading = case last_direction do
      nil -> 0.0
      6 -> 0.0
      dir when is_integer(dir) -> (dir / 6.0) * 2.0 - 1.0
      _ -> 0.0
    end

    # Stamina: energy ratio with sprint threshold awareness
    stamina = if max_energy > 0, do: energy / max_energy, else: 0.5

    [speed, heading, stamina]
  end
end
