defmodule SwaiNode.Domain.DomainBridge do
  @moduledoc """
  Domain bridge implementing macula-neuroevolution domain behaviours.

  Provides domain-specific signals from the 2D world simulation to
  inform silo decision-making in the neuroevolution library.

  ## Signal Categories

  - **ecological**: Food scarcity, population density, carrying capacity
  - **competitive**: Predator/prey ratios, conflict rates, kill rates
  - **cultural**: Behavioral diversity (herbivore/omnivore/carnivore)
  - **temporal**: Stagnation detection, episode timing
  - **resource**: Energy distribution across population

  ## Usage

  Register during application startup:

      :signal_router.register_domain_module(SwaiNode.Domain.DomainBridge)

  Emit signals after each simulation step:

      :signal_router.emit_from_domain(world_state, metrics)

  Or call directly:

      signals = SwaiNode.Domain.DomainBridge.emit_signals(world_state, metrics)
      :signal_router.route(signals)
  """

  # Erlang behaviour - callbacks defined in macula-neuroevolution
  # signal_spec/0 -> [signal_definition()]
  # emit_signals/2 -> [signal()]

  # World configuration defaults (must match WorldServer)
  @default_max_food 150
  @default_starting_population 80
  @default_world_area 800 * 600

  @doc """
  Signal specification for the 2D world domain.

  Defines all signals that this domain can emit to silos.
  """
  def signal_spec do
    [
      # Ecological signals
      %{
        name: :food_scarcity,
        category: :ecological,
        level: :l0,
        range: {0.0, 1.0},
        description: "Food availability (0=abundant, 1=scarce)"
      },
      %{
        name: :population_density,
        category: :ecological,
        level: :l0,
        range: {0.0, 1.0},
        description: "Population density relative to carrying capacity"
      },
      %{
        name: :carrying_capacity_pressure,
        category: :ecological,
        level: :l0,
        range: {0.0, 1.0},
        description: "Pressure from approaching carrying capacity"
      },

      # Competitive signals
      %{
        name: :predator_ratio,
        category: :competitive,
        level: :l0,
        range: {0.0, 1.0},
        description: "Ratio of predators (carnivores+omnivores) to total population"
      },
      %{
        name: :conflict_rate,
        category: :competitive,
        level: :l0,
        range: {0.0, 1.0},
        description: "Attack frequency per agent"
      },
      %{
        name: :lethality_rate,
        category: :competitive,
        level: :l0,
        range: {0.0, 1.0},
        description: "Kill success rate (kills / attacks)"
      },

      # Cultural/behavioral signals
      %{
        name: :behavioral_diversity,
        category: :cultural,
        level: :l0,
        range: {0.0, 1.0},
        description: "Shannon diversity of behavioral types"
      },
      %{
        name: :carnivore_emergence,
        category: :cultural,
        level: :l0,
        range: {0.0, 1.0},
        description: "Proportion of population with predatory behavior"
      },

      # Temporal signals
      %{
        name: :fitness_stagnation,
        category: :temporal,
        level: :l0,
        range: {0.0, 1.0},
        description: "Fitness improvement stagnation (0=improving, 1=stagnant)"
      },

      # Resource signals
      %{
        name: :energy_distribution,
        category: :resource,
        level: :l0,
        range: {0.0, 1.0},
        description: "Energy inequality (0=equal, 1=highly unequal)"
      },
      %{
        name: :starvation_pressure,
        category: :resource,
        level: :l0,
        range: {0.0, 1.0},
        description: "Proportion of population with low energy"
      }
    ]
  end

  @doc """
  Emit signals from current world state and metrics.

  ## Parameters

  - `world_state` - Current simulation state containing:
    - `:agents` - Map of agent id to agent data
    - `:food` - List of food items
    - `:config` - World configuration
    - `:stats` - Cumulative statistics

  - `metrics` - Per-tick or per-evaluation metrics:
    - `:attacks_this_tick` - Attacks in current tick
    - `:kills_this_tick` - Kills in current tick
    - `:prev_best_fitness` - Previous best fitness for stagnation detection
    - `:best_fitness` - Current best fitness
  """
  def emit_signals(world_state, metrics) do
    agents = extract_agents(world_state)
    food = extract_food(world_state)
    config = extract_config(world_state)
    stats = extract_stats(world_state)

    population = length(agents)

    # Skip if no agents
    if population == 0 do
      []
    else
      [
        # Ecological signals
        {:ecological, :food_scarcity, calculate_food_scarcity(food, config)},
        {:ecological, :population_density, calculate_population_density(population, config)},
        {:ecological, :carrying_capacity_pressure, calculate_carrying_pressure(population, config)},

        # Competitive signals
        {:competitive, :predator_ratio, calculate_predator_ratio(agents)},
        {:competitive, :conflict_rate, calculate_conflict_rate(stats, population)},
        {:competitive, :lethality_rate, calculate_lethality_rate(stats)},

        # Cultural signals
        {:cultural, :behavioral_diversity, calculate_behavioral_diversity(agents)},
        {:cultural, :carnivore_emergence, calculate_carnivore_emergence(agents)},

        # Temporal signals
        {:temporal, :fitness_stagnation, calculate_fitness_stagnation(metrics)},

        # Resource signals
        {:resource, :energy_distribution, calculate_energy_distribution(agents)},
        {:resource, :starvation_pressure, calculate_starvation_pressure(agents)}
      ]
    end
  end

  # ===========================================================================
  # Extraction Helpers
  # ===========================================================================

  defp extract_agents(%{agents: agents}) when is_map(agents), do: Map.values(agents)
  defp extract_agents(%{agents: agents}) when is_list(agents), do: agents
  defp extract_agents(_), do: []

  defp extract_food(%{food: food}) when is_list(food), do: food
  defp extract_food(_), do: []

  defp extract_config(%{config: config}), do: config
  defp extract_config(_), do: %{}

  defp extract_stats(%{stats: stats}), do: stats
  defp extract_stats(_), do: %{}

  # ===========================================================================
  # Ecological Signal Calculations
  # ===========================================================================

  defp calculate_food_scarcity(food, config) do
    food_count = length(food)
    max_food = Map.get(config, :max_food, @default_max_food)

    # Scarcity = 1 - (current / max)
    scarcity = 1.0 - food_count / max(1, max_food)
    clamp(scarcity, 0.0, 1.0)
  end

  defp calculate_population_density(population, config) do
    width = Map.get(config, :width, 800)
    height = Map.get(config, :height, 600)
    area = width * height

    # Normalize by expected population per unit area
    expected_density = @default_starting_population / @default_world_area
    actual_density = population / area

    density_ratio = actual_density / max(expected_density, 0.0001)
    clamp(density_ratio, 0.0, 1.0)
  end

  defp calculate_carrying_pressure(population, config) do
    starting_pop = Map.get(config, :starting_population, @default_starting_population)

    # Carrying capacity ~2x starting population
    carrying_capacity = starting_pop * 2

    pressure = population / carrying_capacity
    clamp(pressure, 0.0, 1.0)
  end

  # ===========================================================================
  # Competitive Signal Calculations
  # ===========================================================================

  defp calculate_predator_ratio(agents) do
    total = length(agents)

    {herbivores, _omnivores, carnivores} = classify_agents(agents)
    predators = carnivores + length(agents) - herbivores - carnivores  # omnivores

    ratio = predators / max(1, total)
    clamp(ratio, 0.0, 1.0)
  end

  defp calculate_conflict_rate(stats, population) do
    attacks = Map.get(stats, :attacks, 0)

    # Normalize: expect ~0.1 attacks per agent as "high"
    rate = attacks / max(1, population) / 100.0
    clamp(rate, 0.0, 1.0)
  end

  defp calculate_lethality_rate(stats) do
    attacks = Map.get(stats, :attacks, 0)
    kills = Map.get(stats, :kills, 0)

    if attacks > 0 do
      clamp(kills / attacks, 0.0, 1.0)
    else
      0.0
    end
  end

  # ===========================================================================
  # Cultural Signal Calculations
  # ===========================================================================

  defp calculate_behavioral_diversity(agents) do
    total = length(agents)

    {herbivores, omnivores, carnivores} = classify_agents(agents)

    # Shannon diversity index
    proportions = [herbivores / total, omnivores / total, carnivores / total]
                  |> Enum.filter(&(&1 > 0))

    shannon = -Enum.reduce(proportions, 0.0, fn p, acc ->
      acc + p * :math.log(p)
    end)

    # Normalize by max entropy (log(3) for 3 categories)
    max_entropy = :math.log(3)
    normalized = shannon / max_entropy

    clamp(normalized, 0.0, 1.0)
  end

  defp calculate_carnivore_emergence(agents) do
    total = length(agents)
    {_herbivores, _omnivores, carnivores} = classify_agents(agents)

    clamp(carnivores / max(1, total), 0.0, 1.0)
  end

  defp classify_agents(agents) do
    Enum.reduce(agents, {0, 0, 0}, fn agent, {h, o, c} ->
      kills = Map.get(agent, :kills, 0)
      food_eaten = Map.get(agent, :food_eaten, 0)

      cond do
        kills == 0 -> {h + 1, o, c}
        kills > food_eaten -> {h, o, c + 1}
        true -> {h, o + 1, c}
      end
    end)
  end

  # ===========================================================================
  # Temporal Signal Calculations
  # ===========================================================================

  defp calculate_fitness_stagnation(metrics) do
    prev_best = Map.get(metrics, :prev_best_fitness, 0.0)
    current_best = Map.get(metrics, :best_fitness, 0.0)

    improvement = current_best - prev_best

    # If improvement is negative or very small, we're stagnating
    if improvement < 0.1 do
      # Map small improvements to high stagnation
      stagnation = 1.0 - min(1.0, improvement / 0.1)
      clamp(stagnation, 0.0, 1.0)
    else
      0.0
    end
  end

  # ===========================================================================
  # Resource Signal Calculations
  # ===========================================================================

  defp calculate_energy_distribution(agents) do
    energies = Enum.map(agents, &Map.get(&1, :energy, 100.0))

    if length(energies) < 2 do
      0.0
    else
      # Gini coefficient for inequality
      n = length(energies)
      sorted = Enum.sort(energies)
      mean = Enum.sum(energies) / n

      sum_of_abs_diffs =
        for e1 <- sorted,
            e2 <- sorted,
            reduce: 0.0 do
          acc -> acc + abs(e1 - e2)
        end

      gini = sum_of_abs_diffs / (2 * n * n * max(mean, 0.1))
      clamp(gini, 0.0, 1.0)
    end
  end

  defp calculate_starvation_pressure(agents) do
    # Count agents with less than 30% energy (assuming max 200)
    low_energy_threshold = 60.0

    starving = Enum.count(agents, fn agent ->
      Map.get(agent, :energy, 100.0) < low_energy_threshold
    end)

    clamp(starving / max(1, length(agents)), 0.0, 1.0)
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp clamp(value, min_val, max_val) do
    value |> max(min_val) |> min(max_val)
  end
end
