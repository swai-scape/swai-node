defmodule SwaiNode.DomainSDK.Evaluators.ForagerFitnessEvaluator do
  @moduledoc """
  Fitness evaluator for forager species.

  Foragers are optimized for efficient food gathering:
  - Food consumed is the primary fitness component
  - Survival time matters but less than food
  - Efficiency bonus for food-per-movement ratio

  ## Fitness Formula

  ```
  fitness = food_score + survival_score + efficiency_bonus

  Where:
    food_score = food_eaten × 150.0
    survival_score = ticks_survived × 0.1
    efficiency_bonus = (food_eaten / max(moves, 1)) × 50.0
  ```
  """

  # Implements :agent_evaluator behaviour (Erlang)

  @food_weight 150.0
  @survival_weight 0.1
  @efficiency_weight 50.0

  def name, do: <<"forager_fitness">>

  def calculate_fitness(metrics) when is_map(metrics) do
    food = get_metric(metrics, :food_eaten, 0)
    ticks = get_metric(metrics, :ticks_survived, 0)
    moves = get_metric(metrics, :moves, ticks)

    food_score = food * @food_weight
    survival_score = ticks * @survival_weight
    efficiency_bonus = if moves > 0, do: (food / moves) * @efficiency_weight, else: 0.0

    food_score + survival_score + efficiency_bonus
  end

  def calculate_fitness(_), do: 0.0

  def fitness_components(metrics) when is_map(metrics) do
    food = get_metric(metrics, :food_eaten, 0)
    ticks = get_metric(metrics, :ticks_survived, 0)
    moves = get_metric(metrics, :moves, ticks)

    %{
      food: food * @food_weight,
      survival: ticks * @survival_weight,
      efficiency: if(moves > 0, do: (food / moves) * @efficiency_weight, else: 0.0),
      raw_food: food,
      raw_ticks: ticks,
      raw_moves: moves
    }
  end

  def fitness_components(_), do: %{food: 0.0, survival: 0.0, efficiency: 0.0}

  defp get_metric(metrics, key, default) when is_atom(key) do
    Map.get(metrics, key, Map.get(metrics, Atom.to_string(key), default))
  end
end
