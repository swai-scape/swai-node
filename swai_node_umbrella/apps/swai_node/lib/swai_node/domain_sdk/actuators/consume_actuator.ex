defmodule SwaiNode.DomainSDK.Actuators.ConsumeActuator do
  @moduledoc """
  Consume actuator - allows predators to eat killed prey.

  Takes 1 output value controlling consumption:
  - `output < 0.3` - No consumption attempt
  - `output >= 0.3` - Attempt to consume corpse at current location

  When a predator kills prey, the prey becomes a corpse that can be consumed
  for energy. This actuator controls when to stop and eat.

  Predators must learn to balance:
  - Continuing pursuit of other prey
  - Stopping to consume for energy recovery
  """

  # Implements :agent_actuator behaviour (Erlang)

  @consume_threshold 0.3

  def name, do: <<"consume">>

  def output_count, do: 1

  def act([consume_output], _agent_state, _env_state) do
    consuming = consume_output >= @consume_threshold

    action = %{
      type: :consume,
      active: consuming,
      intensity: consume_output
    }

    {:ok, action}
  end

  def act(_, _, _), do: {:error, :invalid_outputs}
end
