defmodule SwaiNode.DomainSDK.Actuators.SignalActuator do
  @moduledoc """
  Signal actuator for broadcasting to nearby agents.

  Interprets 1 output value as signal strength (0-1).
  Other agents can detect this via their hearing sensors.

  Total: 1 output value
  """

  @behaviour :agent_actuator

  @outputs 1

  @impl :agent_actuator
  def name, do: <<"signal">>

  @impl :agent_actuator
  def output_count, do: @outputs

  @impl :agent_actuator
  def act([signal_raw], _agent_state, _env_state) do
    # Clamp signal to [0, 1]
    signal = signal_raw |> max(0.0) |> min(1.0)

    action = %{
      type: :signal,
      strength: signal
    }

    {:ok, action}
  end

  def act(outputs, _, _), do: {:error, {:invalid_output_count, length(outputs), @outputs}}
end
