defmodule SwaiNode.Domain.DomainBridge do
  @moduledoc """
  Domain bridge implementing macula-neuroevolution domain behaviours.

  Implements all four domain behaviours from macula-neuroevolution:
  - `domain_sensors` - What inputs agents perceive
  - `domain_actuators` - What outputs agents can produce
  - `domain_rewards` - How fitness is computed
  - `domain_signals` - Meta-signals to inform silos

  ## Network Architecture

  **Sensors (37 inputs):**
  - Vision: 24 channels (8 rays × 3 types: food, agent, wall)
  - Hearing: 4 channels (signals from nearest agents)
  - Smell: 3 channels (food, prey, threat density)
  - Proprioception: 6 channels (energy, age, direction×2, signal, generation)

  **Actuators (6 outputs):**
  - Movement: turn (-1 to 1), move (0 to 1)
  - Actions: eat, reproduce (thresholds, currently automatic)
  - Communication: signal (0 to 1)
  - Combat: attack (threshold)

  **Rewards:**
  - Survival: +1 per tick alive
  - Eating: +50 per food consumed
  - Killing: +100 per successful kill
  - Death: -0 (handled by ending evaluation)

  ## Usage

  Register during application startup:

      :signal_router.register_domain_module(SwaiNode.Domain.DomainBridge)

  For evaluation, use the spec functions to build network topology:

      sensors = SwaiNode.Domain.DomainBridge.sensor_spec()
      actuators = SwaiNode.Domain.DomainBridge.actuator_spec()
  """

  # Erlang behaviours - callbacks defined in macula-neuroevolution
  # domain_sensors: sensor_spec/0, read_sensors/1
  # domain_actuators: actuator_spec/0, apply_actuators/2
  # domain_rewards: reward_spec/0, compute_rewards/2
  # domain_signals: signal_spec/0, emit_signals/2

  # World configuration defaults (must match WorldServer)
  @default_max_food 150
  @default_starting_population 80
  @default_world_area 800 * 600

  # Sensor/actuator constants (must match AgentBrain)
  @max_energy 200.0
  @max_age 10000
  @max_generation 100

  # =============================================================================
  # domain_sensors behaviour
  # =============================================================================

  @doc """
  Sensor specification for the 2D world domain.

  Defines all sensory inputs available to agents (37 total).
  """
  def sensor_spec do
    [
      # Vision - 8 rays × 3 channels = 24 inputs
      %{
        name: :vision_food,
        dimension: 8,
        range: {0.0, 1.0},
        level: :l0,
        category: :perception,
        description: "Distance to food in 8 directions (0=far, 1=near)"
      },
      %{
        name: :vision_agent,
        dimension: 8,
        range: {0.0, 1.0},
        level: :l0,
        category: :perception,
        description: "Distance to other agents in 8 directions"
      },
      %{
        name: :vision_wall,
        dimension: 8,
        range: {0.0, 1.0},
        level: :l0,
        category: :perception,
        description: "Distance to walls in 8 directions"
      },

      # Hearing - signals from 4 nearest agents
      %{
        name: :hearing,
        dimension: 4,
        range: {0.0, 1.0},
        level: :l0,
        category: :communication,
        description: "Broadcast signals from 4 nearest agents"
      },

      # Smell - density of nearby entities
      %{
        name: :smell_food,
        dimension: 1,
        range: {0.0, 1.0},
        level: :l0,
        category: :perception,
        description: "Food density in smell range"
      },
      %{
        name: :smell_prey,
        dimension: 1,
        range: {0.0, 1.0},
        level: :l0,
        category: :perception,
        description: "Prey (low-energy agents) density"
      },
      %{
        name: :smell_threat,
        dimension: 1,
        range: {0.0, 1.0},
        level: :l0,
        category: :perception,
        description: "Threat (high-energy agents) density"
      },

      # Proprioception - internal state
      %{
        name: :energy,
        dimension: 1,
        range: {0.0, 1.0},
        level: :l0,
        category: :proprioception,
        description: "Current energy level normalized"
      },
      %{
        name: :age,
        dimension: 1,
        range: {0.0, 1.0},
        level: :l0,
        category: :proprioception,
        description: "Age normalized"
      },
      %{
        name: :direction,
        dimension: 2,
        range: {-1.0, 1.0},
        level: :l0,
        category: :proprioception,
        description: "Facing direction as (sin, cos)"
      },
      %{
        name: :own_signal,
        dimension: 1,
        range: {0.0, 1.0},
        level: :l0,
        category: :proprioception,
        description: "Own broadcast signal value"
      },
      %{
        name: :generation,
        dimension: 1,
        range: {0.0, 1.0},
        level: :l0,
        category: :proprioception,
        description: "Generation number normalized"
      }
    ]
  end

  @doc """
  Read sensor values from domain state.

  Returns a map of sensor name to list of float values.
  """
  def read_sensors(domain_state) do
    agent = Map.get(domain_state, :agent, %{})
    vision = Map.get(domain_state, :vision, List.duplicate(0.0, 24))
    hearing = Map.get(domain_state, :hearing, List.duplicate(0.0, 4))
    smell = Map.get(domain_state, :smell, [0.0, 0.0, 0.0])

    # Split vision into 3 channels (food, agent, wall)
    {vision_food, rest} = Enum.split(vision, 8)
    {vision_agent, vision_wall} = Enum.split(rest, 8)

    # Split smell into 3 values
    [smell_food, smell_prey, smell_threat] = normalize_smell(smell)

    # Proprioceptive sensors
    energy = Map.get(agent, :energy, 100.0)
    age = Map.get(agent, :age, 0)
    direction = Map.get(agent, :direction, 0.0)
    signal = Map.get(agent, :signal, 0.5)
    generation = Map.get(agent, :generation, 0)

    %{
      vision_food: vision_food,
      vision_agent: vision_agent,
      vision_wall: vision_wall,
      hearing: hearing,
      smell_food: [smell_food],
      smell_prey: [smell_prey],
      smell_threat: [smell_threat],
      energy: [min(energy / @max_energy, 1.0)],
      age: [min(age / @max_age, 1.0)],
      direction: [:math.sin(direction), :math.cos(direction)],
      own_signal: [signal],
      generation: [min(generation / @max_generation, 1.0)]
    }
  end

  defp normalize_smell(smell) when length(smell) == 3, do: smell
  defp normalize_smell(_), do: [0.0, 0.0, 0.0]

  # =============================================================================
  # domain_actuators behaviour
  # =============================================================================

  @doc """
  Actuator specification for the 2D world domain.

  Defines all outputs the network can produce (6 total).
  """
  def actuator_spec do
    [
      %{
        name: :turn,
        dimension: 1,
        range: {-1.0, 1.0},
        level: :l0,
        category: :motor,
        description: "Rotation amount (-1=left, 1=right)"
      },
      %{
        name: :move,
        dimension: 1,
        range: {0.0, 1.0},
        level: :l0,
        category: :motor,
        description: "Forward movement speed"
      },
      %{
        name: :eat,
        dimension: 1,
        range: {0.0, 1.0},
        level: :l0,
        category: :action,
        description: "Eat intention (currently automatic, >0.5 = want to eat)"
      },
      %{
        name: :reproduce,
        dimension: 1,
        range: {0.0, 1.0},
        level: :l0,
        category: :action,
        description: "Reproduce intention (currently automatic, >0.5 = want to reproduce)"
      },
      %{
        name: :signal,
        dimension: 1,
        range: {0.0, 1.0},
        level: :l0,
        category: :communication,
        description: "Broadcast signal value for other agents to hear"
      },
      %{
        name: :attack,
        dimension: 1,
        range: {0.0, 1.0},
        level: :l0,
        category: :action,
        description: "Attack intention (>0 = attempt attack on nearest agent)"
      }
    ]
  end

  @doc """
  Apply actuator outputs to domain state.

  Converts raw network outputs to actions and updates agent state.
  """
  def apply_actuators(outputs, domain_state) do
    agent = Map.get(domain_state, :agent, %{})
    config = Map.get(domain_state, :config, %{})

    # Parse outputs (expecting map of actuator name to [float])
    turn = get_actuator_value(outputs, :turn, 0.0)
    move = get_actuator_value(outputs, :move, 0.0)
    eat = get_actuator_value(outputs, :eat, 0.0)
    reproduce = get_actuator_value(outputs, :reproduce, 0.0)
    signal = get_actuator_value(outputs, :signal, 0.5)
    attack = get_actuator_value(outputs, :attack, 0.0)

    # Apply movement
    width = Map.get(config, :width, 800)
    height = Map.get(config, :height, 600)
    agent_radius = 5.0
    move_cost = 0.05

    new_direction = agent.direction + turn * 0.1
    move_speed = max(0.0, move) * 3.0

    new_x = agent.x + :math.cos(new_direction) * move_speed
    new_y = agent.y + :math.sin(new_direction) * move_speed

    # Clamp to bounds
    new_x = new_x |> max(agent_radius) |> min(width - agent_radius)
    new_y = new_y |> max(agent_radius) |> min(height - agent_radius)

    # Update energy
    new_energy = agent.energy - move_cost

    # Update agent
    updated_agent = %{agent |
      x: new_x,
      y: new_y,
      direction: new_direction,
      energy: new_energy,
      age: agent.age + 1,
      fitness: agent.fitness + 1,
      wants_eat: eat > 0.5,
      wants_reproduce: reproduce > 0.5,
      signal: signal,
      wants_attack: attack > 0.0
    }

    %{domain_state | agent: updated_agent}
  end

  defp get_actuator_value(outputs, name, default) do
    case Map.get(outputs, name) do
      [value | _] when is_number(value) -> value
      value when is_number(value) -> value
      _ -> default
    end
  end

  # =============================================================================
  # domain_rewards behaviour
  # =============================================================================

  @doc """
  Reward specification for the 2D world domain.

  Defines all reward signals that can be computed from agent performance.
  """
  def reward_spec do
    [
      %{
        name: :survival,
        weight: 1.0,
        level: :l0,
        sign: :reward,
        category: :temporal,
        description: "Reward per tick alive"
      },
      %{
        name: :eating,
        weight: 50.0,
        level: :l0,
        sign: :reward,
        category: :ecological,
        description: "Reward for consuming food"
      },
      %{
        name: :killing,
        weight: 100.0,
        level: :l0,
        sign: :reward,
        category: :competitive,
        description: "Reward for successful kill"
      },
      %{
        name: :energy_efficiency,
        weight: 0.1,
        level: :l0,
        sign: :reward,
        category: :resource,
        description: "Reward for maintaining high energy"
      },
      %{
        name: :starvation,
        weight: 0.0,
        level: :l0,
        sign: :punishment,
        category: :temporal,
        description: "Punishment for death (implicit - ends evaluation)"
      }
    ]
  end

  @doc """
  Compute rewards from domain state and metrics.

  Returns a map of reward name to float value.
  """
  def compute_rewards(domain_state, metrics) do
    agent = Map.get(domain_state, :agent, %{})

    # Survival reward (1 per tick)
    ticks = Map.get(metrics, :ticks_survived, Map.get(agent, :age, 0))

    # Eating reward
    food_eaten = Map.get(metrics, :food_eaten, Map.get(agent, :food_eaten, 0))

    # Killing reward
    kills = Map.get(metrics, :kills, Map.get(agent, :kills, 0))

    # Energy efficiency (current energy as fraction of max)
    energy = Map.get(agent, :energy, 100.0)
    energy_ratio = energy / @max_energy

    %{
      survival: ticks * 1.0,
      eating: food_eaten * 50.0,
      killing: kills * 100.0,
      energy_efficiency: energy_ratio * ticks * 0.1,
      starvation: 0.0  # Implicit - evaluation ends on death
    }
  end

  @doc """
  Calculate total fitness from reward signals.

  Applies weights from reward_spec to compute aggregate fitness.
  """
  def calculate_fitness(rewards) do
    spec_map = reward_spec() |> Enum.map(&{&1.name, &1}) |> Map.new()

    Enum.reduce(rewards, 0.0, fn {name, value}, acc ->
      case Map.get(spec_map, name) do
        %{weight: weight, sign: :reward} -> acc + value * weight / weight  # Already weighted in compute
        %{weight: weight, sign: :punishment} -> acc - value * weight / weight
        _ -> acc + value
      end
    end)
  end

  # =============================================================================
  # domain_signals behaviour
  # =============================================================================

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
