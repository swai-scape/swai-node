defmodule SwaiNode.DomainSDK.Actuators.AttackActuator do
  @moduledoc """
  Attack actuator for combat with other agents.

  Interprets 1 output value as attack intention.
  Triggers attack if value exceeds threshold (0.5).

  Total: 1 output value
  """

  # Implements :agent_actuator behaviour (Erlang)

  @outputs 1
  @attack_threshold 0.5

  def name, do: <<"attack">>

  def output_count, do: @outputs

  def act([attack_raw], _agent_state, _env_state) do
    attack = attack_raw > @attack_threshold

    action = %{
      type: :attack,
      attacking: attack,
      intensity: attack_raw
    }

    {:ok, action}
  end

  def act(outputs, _, _), do: {:error, {:invalid_output_count, length(outputs), @outputs}}
end
