defmodule SwaiNode.DomainSDK.Actuators.SprintActuator do
  @moduledoc """
  Sprint actuator - enables burst speed for pursuit.

  Takes 1 output value controlling sprint:
  - `output < 0.5` - Normal movement speed
  - `output >= 0.5` - Sprint (2x movement, high energy cost)

  Sprinting allows predators to:
  - Close distance quickly on prey
  - Intercept fleeing targets
  - Trade energy for speed in pursuit
  """

  @behaviour :agent_actuator

  @sprint_threshold 0.5

  @impl :agent_actuator
  def name, do: <<"sprint">>

  @impl :agent_actuator
  def output_count, do: 1

  @impl :agent_actuator
  def act([sprint_output], agent_state, _env_state) do
    energy = Map.get(agent_state, :energy, 0)
    sprint_cost = Map.get(agent_state, :sprint_cost, 1.0)

    # Can only sprint if enough energy
    sprinting = sprint_output >= @sprint_threshold and energy > sprint_cost * 2

    action = %{
      type: :sprint,
      active: sprinting,
      intensity: sprint_output
    }

    {:ok, action}
  end

  def act(_, _, _), do: {:error, :invalid_outputs}
end
