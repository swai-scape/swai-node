defmodule SwaiNode.DomainSDK.Actuators.StealthActuator do
  @moduledoc """
  Stealth actuator - reduces predator's visibility to prey.

  Takes 1 output value controlling stealth mode:
  - `output < 0.3` - No stealth (normal visibility)
  - `output >= 0.3` - Stealth mode (reduced signal, costs energy)

  When stealthed:
  - Predator's signal output is suppressed
  - Vision sensors of prey are less likely to detect
  - Continuous energy cost while active
  """

  @behaviour :agent_actuator

  @stealth_threshold 0.3

  @impl :agent_actuator
  def name, do: <<"stealth">>

  @impl :agent_actuator
  def output_count, do: 1

  @impl :agent_actuator
  def act([stealth_output], _agent_state, _env_state) do
    stealthing = stealth_output >= @stealth_threshold

    action = %{
      type: :stealth,
      active: stealthing,
      intensity: stealth_output
    }

    {:ok, action}
  end

  def act(_, _, _), do: {:error, :invalid_outputs}
end
