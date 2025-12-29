defmodule SwaiNode.DomainSDK.Evaluators.PredatorFitnessEvaluator do
  @moduledoc """
  Fitness evaluator for predator species.

  Predators are optimized for successful hunting:
  - Kills are the primary fitness component
  - Energy gained from kills matters
  - Survival time is secondary
  - Hunt efficiency bonus

  ## Fitness Formula

  ```
  fitness = kill_score + energy_score + survival_score + efficiency_bonus

  Where:
    kill_score = kills × 200.0
    energy_score = energy_from_kills × 0.5
    survival_score = ticks_survived × 0.05
    efficiency_bonus = (kills / max(attacks, 1)) × 100.0
  ```

  The efficiency bonus rewards predators that don't waste energy on
  failed attacks (precision hunting).
  """

  # Implements :agent_evaluator behaviour (Erlang)

  @kill_weight 200.0
  @energy_weight 0.5
  @survival_weight 0.05
  @efficiency_weight 100.0

  def name, do: <<"predator_fitness">>

  def calculate_fitness(metrics) when is_map(metrics) do
    kills = get_metric(metrics, :kills, 0)
    energy_gained = get_metric(metrics, :energy_from_kills, 0)
    ticks = get_metric(metrics, :ticks_survived, 0)
    attacks = get_metric(metrics, :attacks, 0)

    kill_score = kills * @kill_weight
    energy_score = energy_gained * @energy_weight
    survival_score = ticks * @survival_weight

    # Efficiency: kills per attack (avoid wasteful attacks)
    efficiency_bonus = if attacks > 0 do
      (kills / attacks) * @efficiency_weight
    else
      0.0
    end

    kill_score + energy_score + survival_score + efficiency_bonus
  end

  def calculate_fitness(_), do: 0.0

  def fitness_components(metrics) when is_map(metrics) do
    kills = get_metric(metrics, :kills, 0)
    energy_gained = get_metric(metrics, :energy_from_kills, 0)
    ticks = get_metric(metrics, :ticks_survived, 0)
    attacks = get_metric(metrics, :attacks, 0)

    %{
      kills: kills * @kill_weight,
      energy: energy_gained * @energy_weight,
      survival: ticks * @survival_weight,
      efficiency: if(attacks > 0, do: (kills / attacks) * @efficiency_weight, else: 0.0),
      raw_kills: kills,
      raw_attacks: attacks,
      raw_energy_gained: energy_gained,
      raw_ticks: ticks,
      kill_rate: if(attacks > 0, do: kills / attacks, else: 0.0)
    }
  end

  def fitness_components(_), do: %{kills: 0.0, energy: 0.0, survival: 0.0, efficiency: 0.0}

  defp get_metric(metrics, key, default) when is_atom(key) do
    Map.get(metrics, key, Map.get(metrics, Atom.to_string(key), default))
  end
end
