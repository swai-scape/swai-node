defmodule SwaiNode.DomainSDK.Actuators.MovementActuator do
  @moduledoc """
  Movement actuator for hex-based locomotion.

  Interprets 7 output values as direction preferences:
  - East, Northeast, Northwest, West, Southwest, Southeast, Stay

  Uses softmax to convert outputs to probability distribution,
  then selects the direction with highest probability.

  Total: 7 output values
  """

  @behaviour :agent_actuator

  @outputs 7
  @stay_penalty 0.2

  @impl :agent_actuator
  def name, do: <<"movement">>

  @impl :agent_actuator
  def output_count, do: @outputs

  @impl :agent_actuator
  def act(outputs, _agent_state, _env_state) when length(outputs) == @outputs do
    # Apply stay penalty to discourage not moving
    adjusted = apply_stay_penalty(outputs)

    # Apply softmax for probability distribution
    probs = softmax(adjusted)

    # Find best direction
    {_best_prob, best_idx} =
      probs
      |> Enum.with_index()
      |> Enum.max_by(fn {prob, _} -> prob end)

    action = %{
      type: :move,
      direction: direction_to_atom(best_idx),
      direction_index: best_idx,
      direction_probs: probs
    }

    {:ok, action}
  end

  def act(outputs, _, _), do: {:error, {:invalid_output_count, length(outputs), @outputs}}

  defp apply_stay_penalty(outputs) do
    outputs
    |> Enum.with_index()
    |> Enum.map(fn {val, idx} ->
      if idx == 6, do: val - @stay_penalty, else: val
    end)
  end

  defp softmax(values) do
    max_val = Enum.max(values)
    exps = Enum.map(values, fn v -> :math.exp(v - max_val) end)
    sum = Enum.sum(exps)
    if sum > 0, do: Enum.map(exps, &(&1 / sum)), else: List.duplicate(1.0 / length(values), length(values))
  end

  defp direction_to_atom(0), do: :east
  defp direction_to_atom(1), do: :northeast
  defp direction_to_atom(2), do: :northwest
  defp direction_to_atom(3), do: :west
  defp direction_to_atom(4), do: :southwest
  defp direction_to_atom(5), do: :southeast
  defp direction_to_atom(_), do: :stay
end
