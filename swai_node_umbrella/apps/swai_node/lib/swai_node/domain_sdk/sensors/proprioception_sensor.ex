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

  @behaviour :agent_sensor

  @impl :agent_sensor
  def name, do: <<"proprioception">>

  @impl :agent_sensor
  def input_count, do: 3

  @impl :agent_sensor
  def read(agent_state, _env_state) do
    last_direction = Map.get(agent_state, :last_direction, 6)
    energy = Map.get(agent_state, :energy, 100.0)
    max_energy = Map.get(agent_state, :max_energy, 400.0)
    sprinting = Map.get(agent_state, :sprinting, false)

    # Speed: 0 if stationary, 1 if moving, 2 if sprinting
    speed = cond do
      sprinting -> 1.0
      last_direction == 6 -> 0.0
      true -> 0.5
    end

    # Heading: normalized direction
    heading = if last_direction == 6 do
      0.0
    else
      (last_direction / 6.0) * 2.0 - 1.0
    end

    # Stamina: energy ratio with sprint threshold awareness
    stamina = energy / max_energy

    [speed, heading, stamina]
  end
end
