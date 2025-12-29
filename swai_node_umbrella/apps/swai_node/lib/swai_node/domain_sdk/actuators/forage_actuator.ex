defmodule SwaiNode.DomainSDK.Actuators.ForageActuator do
  @moduledoc """
  Forage actuator - controls eating behavior.

  Takes 1 output value representing foraging intention.
  When above threshold, the agent attempts to eat food at current location.

  ## Output Interpretation

  - `output < 0.3` - No foraging (moving/exploring)
  - `output >= 0.3` - Attempt to forage (eat if food present)

  This allows evolved agents to learn when to stop and eat vs keep moving.
  """

  # Implements :agent_actuator behaviour (Erlang)

  @forage_threshold 0.3

  def name, do: <<"forage">>

  def output_count, do: 1

  def act([forage_output], agent_state, _env_state) do
    foraging = forage_output >= @forage_threshold

    action = %{
      type: :forage,
      foraging: foraging,
      intensity: forage_output
    }

    {:ok, action}
  end

  def act(_, _, _), do: {:error, :invalid_outputs}
end
