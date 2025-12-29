defmodule SwaiNode.DomainSDK.ForagerEvaluator do
  @moduledoc """
  Fitness evaluator for foraging agents.

  Implements the `agent_evaluator` behaviour from the Domain SDK.

  ## Fitness Function

  ```
  fitness = survival_score + food_score + kill_score
  ```

  | Component | Weight | Description                |
  |-----------|--------|----------------------------|
  | Survival  | 0.1    | Points per tick survived   |
  | Food      | 150.0  | Points per food eaten      |
  | Kills     | 100.0  | Points per kill            |

  Food is weighted heavily to encourage foraging behavior.
  Survival is weighted low to discourage passive "hiding" strategies.
  """

  @behaviour :agent_evaluator

  @survival_weight 0.1
  @food_weight 150.0
  @kill_weight 100.0

  @impl :agent_evaluator
  def name, do: <<"forager_fitness">>

  @impl :agent_evaluator
  def calculate_fitness(metrics) when is_map(metrics) do
    ticks = get_metric(metrics, :ticks_survived, 0)
    food = get_metric(metrics, :food_eaten, 0)
    kills = get_metric(metrics, :kills, 0)

    ticks * @survival_weight + food * @food_weight + kills * @kill_weight
  end

  def calculate_fitness(_), do: 0.0

  @impl :agent_evaluator
  def fitness_components(metrics) when is_map(metrics) do
    ticks = get_metric(metrics, :ticks_survived, 0)
    food = get_metric(metrics, :food_eaten, 0)
    kills = get_metric(metrics, :kills, 0)

    %{
      survival: ticks * @survival_weight,
      food: food * @food_weight,
      kills: kills * @kill_weight
    }
  end

  def fitness_components(_), do: %{survival: 0.0, food: 0.0, kills: 0.0}

  defp get_metric(metrics, key, default) when is_atom(key) do
    Map.get(metrics, key, Map.get(metrics, Atom.to_string(key), default))
  end
end
