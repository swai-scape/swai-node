defmodule SwaiNode.DomainSDK.MultiSpeciesHexArena do
  @moduledoc """
  Multi-species hex arena environment for coevolution.

  Extends the base HexArenaEnvironment to support multiple species
  with inter-species interactions.

  ## Supported Species

  - **Foragers** (green) - Eat food, avoid predators
  - **Predators** (red) - Hunt foragers, consume corpses

  ## Interaction Matrix

  ```
  ┌────────────┬──────────┬──────────┐
  │            │ Forager  │ Predator │
  ├────────────┼──────────┼──────────┤
  │ Forager    │ compete  │ prey     │
  │ Predator   │ hunt     │ compete  │
  └────────────┴──────────┴──────────┘
  ```

  ## Episode Flow

  1. Initialize environment with walls and food
  2. Spawn foragers in center, predators at edges
  3. Each tick:
     - Process all agent actions
     - Handle predator-prey interactions
     - Spawn new food
     - Remove dead agents
  4. Terminal when max ticks or all of one species dead
  """

  # Implements :multispecies_environment behaviour (Erlang)

  alias SwaiNode.Simulation.{Hex, HexMaze}

  # Defaults
  @default_arena_radius 50
  @default_max_ticks 1000
  @default_wall_percent 8
  @default_max_food 100
  @default_food_spawn_rate 0.5

  # Species defaults
  @forager_defaults %{
    energy: 150.0,
    max_energy: 300.0,
    metabolism: 0.3,
    eat_gain: 40.0
  }

  @predator_defaults %{
    energy: 200.0,
    max_energy: 400.0,
    metabolism: 0.5,
    attack_damage: 60.0,
    kill_energy_gain: 80.0,
    sprint_cost: 1.5,
    stealth_cost: 0.3
  }

  # Callbacks

  def name, do: <<"multispecies_hex_arena">>

  def supported_species, do: [:forager, :predator]

  def init(config) do
    arena_radius = Map.get(config, :arena_radius, @default_arena_radius)
    max_ticks = Map.get(config, :max_ticks, @default_max_ticks)
    wall_percent = Map.get(config, :wall_percent, @default_wall_percent)

    walls = HexMaze.generate_scatter(arena_radius,
      wall_percent: wall_percent,
      open_center_radius: 5
    )

    food = spawn_initial_food(walls, arena_radius, 20)

    env_state = %{
      arena_radius: arena_radius,
      max_ticks: max_ticks,
      max_food: Map.get(config, :max_food, @default_max_food),
      food_spawn_rate: Map.get(config, :food_spawn_rate, @default_food_spawn_rate),
      walls: walls,
      food: food,
      corpses: %{},  # Dead agents that can be consumed
      agents: %{},
      species_counts: %{forager: 0, predator: 0},
      tick: 0,
      kills: [],  # Log of kills for metrics
      forager_config: Map.merge(@forager_defaults, Map.get(config, :forager, %{})),
      predator_config: Map.merge(@predator_defaults, Map.get(config, :predator, %{}))
    }

    {:ok, env_state}
  end

  def spawn_agent(agent_id, species, env_state) do
    config = get_species_config(species, env_state)
    spawn_zone = Map.get(config, :spawn_zone, :center)
    hex = find_spawn_location(spawn_zone, env_state)

    agent_state = %{
      id: agent_id,
      species: species,
      hex: hex,
      energy: Map.get(config, :energy, 150.0),
      max_energy: Map.get(config, :max_energy, 300.0),
      age: 0,
      signal: 0.5,
      generation: 0,
      food_eaten: 0,
      kills: 0,
      attacks: 0,
      energy_from_kills: 0,
      last_direction: nil,
      sprinting: false,
      stealthed: false,
      alive: true
    }

    # Update species count
    counts = Map.get(env_state, :species_counts, %{})
    new_counts = Map.update(counts, species, 1, &(&1 + 1))

    updated_env = env_state
    |> Map.put(:species_counts, new_counts)
    |> put_in([:agents, agent_id], agent_state)

    {:ok, agent_state, updated_env}
  end

  def tick(agent_state, env_state) do
    new_tick = Map.get(env_state, :tick, 0) + 1
    env_state = Map.put(env_state, :tick, new_tick)

    # Apply metabolism
    species = Map.get(agent_state, :species, :forager)
    config = get_species_config(species, env_state)
    metabolism = Map.get(config, :metabolism, 0.3)

    # Extra cost if sprinting or stealthed
    extra_cost = calculate_extra_costs(agent_state, config)
    total_cost = metabolism + extra_cost

    agent_state = Map.update(agent_state, :energy, 0, &(&1 - total_cost))
    agent_state = Map.update(agent_state, :age, 0, &(&1 + 1))

    # Spawn food
    env_state = maybe_spawn_food(env_state)

    # Decay corpses
    env_state = decay_corpses(env_state)

    {:ok, agent_state, env_state}
  end

  def apply_action(action, agent_state, env_state) do
    species = Map.get(agent_state, :species, :forager)

    {agent_state, env_state} = case species do
      :forager -> apply_forager_action(action, agent_state, env_state)
      :predator -> apply_predator_action(action, agent_state, env_state)
      _ -> {agent_state, env_state}
    end

    # Update agent in environment
    agent_id = Map.get(agent_state, :id)
    env_state = put_in(env_state, [:agents, agent_id], agent_state)

    {:ok, agent_state, env_state}
  end

  def handle_interaction(agent1, agent2, env_state) do
    species1 = Map.get(agent1, :species)
    species2 = Map.get(agent2, :species)

    case interaction_type(species1, species2) do
      :hunt ->
        handle_hunt(agent1, agent2, env_state)
      :prey ->
        # Swap and handle as hunt
        handle_hunt(agent2, agent1, env_state)
      :compete ->
        handle_competition(agent1, agent2, env_state)
      _ ->
        {:ok, agent1, agent2, env_state}
    end
  end

  def interaction_type(:predator, :forager), do: :hunt
  def interaction_type(:forager, :predator), do: :prey
  def interaction_type(same, same), do: :compete
  def interaction_type(_, _), do: :ignore

  def is_terminal(agent_state, env_state) do
    energy = Map.get(agent_state, :energy, 0)
    alive = Map.get(agent_state, :alive, true)
    tick = Map.get(env_state, :tick, 0)
    max_ticks = Map.get(env_state, :max_ticks, @default_max_ticks)

    not alive or energy <= 0 or tick >= max_ticks
  end

  def extract_metrics(agent_state, env_state) do
    %{
      species: Map.get(agent_state, :species),
      ticks_survived: Map.get(agent_state, :age, 0),
      food_eaten: Map.get(agent_state, :food_eaten, 0),
      kills: Map.get(agent_state, :kills, 0),
      attacks: Map.get(agent_state, :attacks, 0),
      energy_from_kills: Map.get(agent_state, :energy_from_kills, 0),
      final_energy: Map.get(agent_state, :energy, 0),
      final_tick: Map.get(env_state, :tick, 0),
      alive: Map.get(agent_state, :alive, true)
    }
  end

  def extract_species_metrics(species, agent_states, env_state) do
    alive = Enum.filter(agent_states, &Map.get(&1, :alive, true))
    dead = Enum.filter(agent_states, &(not Map.get(&1, :alive, true)))

    total_food = Enum.sum(Enum.map(agent_states, &Map.get(&1, :food_eaten, 0)))
    total_kills = Enum.sum(Enum.map(agent_states, &Map.get(&1, :kills, 0)))
    avg_survival = if length(agent_states) > 0 do
      Enum.sum(Enum.map(agent_states, &Map.get(&1, :age, 0))) / length(agent_states)
    else
      0
    end

    %{
      species: species,
      total_agents: length(agent_states),
      alive_count: length(alive),
      dead_count: length(dead),
      total_food_eaten: total_food,
      total_kills: total_kills,
      average_survival: avg_survival,
      tick: Map.get(env_state, :tick, 0)
    }
  end

  # Private helpers

  defp get_species_config(:forager, env_state), do: Map.get(env_state, :forager_config, @forager_defaults)
  defp get_species_config(:predator, env_state), do: Map.get(env_state, :predator_config, @predator_defaults)
  defp get_species_config(_, _), do: @forager_defaults

  defp find_spawn_location(:center, env_state) do
    walls = Map.get(env_state, :walls, MapSet.new())
    # Find open hex near center
    find_open_near({0, 0}, walls, 5)
  end

  defp find_spawn_location(:edge, env_state) do
    arena_radius = Map.get(env_state, :arena_radius, @default_arena_radius)
    walls = Map.get(env_state, :walls, MapSet.new())
    # Random edge position
    angle = :rand.uniform() * 2 * :math.pi()
    q = round(:math.cos(angle) * (arena_radius - 2))
    r = round(:math.sin(angle) * (arena_radius - 2))
    find_open_near({q, r}, walls, 3)
  end

  defp find_spawn_location(:random, env_state) do
    arena_radius = Map.get(env_state, :arena_radius, @default_arena_radius)
    walls = Map.get(env_state, :walls, MapSet.new())
    case Hex.random_open_hex(arena_radius, walls) do
      nil -> {0, 0}
      hex -> hex
    end
  end

  defp find_spawn_location(_, env_state), do: find_spawn_location(:center, env_state)

  defp find_open_near(hex, walls, radius) do
    {q, r} = hex
    candidates = for dq <- -radius..radius, dr <- -radius..radius, do: {q + dq, r + dr}
    open = Enum.reject(candidates, &MapSet.member?(walls, &1))
    case open do
      [] -> hex
      list -> Enum.random(list)
    end
  end

  defp calculate_extra_costs(agent_state, config) do
    sprint_cost = if Map.get(agent_state, :sprinting, false) do
      Map.get(config, :sprint_cost, 0)
    else
      0
    end

    stealth_cost = if Map.get(agent_state, :stealthed, false) do
      Map.get(config, :stealth_cost, 0)
    else
      0
    end

    sprint_cost + stealth_cost
  end

  defp apply_forager_action(action, agent_state, env_state) do
    agent_state = apply_movement(action, agent_state, env_state)
    agent_state = apply_signal(action, agent_state)
    {agent_state, env_state} = apply_foraging(action, agent_state, env_state)
    {agent_state, env_state}
  end

  defp apply_predator_action(action, agent_state, env_state) do
    agent_state = apply_stealth(action, agent_state)
    agent_state = apply_sprint(action, agent_state)
    agent_state = apply_movement(action, agent_state, env_state)
    {agent_state, env_state} = apply_attack(action, agent_state, env_state)
    {agent_state, env_state} = apply_consume(action, agent_state, env_state)
    agent_state = apply_signal(action, agent_state)
    {agent_state, env_state}
  end

  defp apply_movement(action, agent_state, env_state) do
    direction_idx = Map.get(action, :direction_index, 6)
    walls = Map.get(env_state, :walls, MapSet.new())
    arena_radius = Map.get(env_state, :arena_radius, @default_arena_radius)
    current_hex = Map.get(agent_state, :hex, {0, 0})

    # Sprint doubles movement (move twice)
    moves = if Map.get(agent_state, :sprinting, false), do: 2, else: 1

    new_hex = Enum.reduce(1..moves, current_hex, fn _, hex ->
      compute_new_hex(hex, direction_idx, walls, arena_radius)
    end)

    %{agent_state |
      hex: new_hex,
      last_direction: direction_idx
    }
  end

  defp compute_new_hex(current_hex, 6, _walls, _radius), do: current_hex
  defp compute_new_hex(current_hex, direction_idx, walls, arena_radius) do
    target = Hex.neighbor(current_hex, direction_idx)
    if Hex.in_bounds?(target, arena_radius) and not MapSet.member?(walls, target) do
      target
    else
      current_hex
    end
  end

  defp apply_signal(action, agent_state) do
    signal = Map.get(action, :strength, Map.get(action, :signal, 0.5))
    # Stealth suppresses signal
    effective_signal = if Map.get(agent_state, :stealthed, false), do: signal * 0.1, else: signal
    %{agent_state | signal: effective_signal}
  end

  defp apply_stealth(action, agent_state) do
    stealthed = Map.get(action, :active, false) and Map.get(action, :type) == :stealth
    %{agent_state | stealthed: stealthed}
  end

  defp apply_sprint(action, agent_state) do
    sprinting = Map.get(action, :active, false) and Map.get(action, :type) == :sprint
    %{agent_state | sprinting: sprinting}
  end

  defp apply_foraging(action, agent_state, env_state) do
    foraging = Map.get(action, :foraging, false)

    if foraging do
      hex = Map.get(agent_state, :hex)
      food = Map.get(env_state, :food, %{})
      config = get_species_config(:forager, env_state)
      eat_gain = Map.get(config, :eat_gain, 40.0)
      max_energy = Map.get(agent_state, :max_energy, 300.0)

      case Map.get(food, hex) do
        nil ->
          {agent_state, env_state}

        _food_data ->
          updated_agent = %{agent_state |
            energy: min(Map.get(agent_state, :energy, 0) + eat_gain, max_energy),
            food_eaten: Map.get(agent_state, :food_eaten, 0) + 1
          }
          updated_env = Map.put(env_state, :food, Map.delete(food, hex))
          {updated_agent, updated_env}
      end
    else
      {agent_state, env_state}
    end
  end

  defp apply_attack(action, agent_state, env_state) do
    attacking = Map.get(action, :attacking, false)

    if attacking do
      hex = Map.get(agent_state, :hex)
      agents = Map.get(env_state, :agents, %{})
      config = get_species_config(:predator, env_state)
      attack_damage = Map.get(config, :attack_damage, 60.0)
      kill_energy = Map.get(config, :kill_energy_gain, 80.0)

      # Find adjacent prey
      neighbors = Hex.neighbors(hex)
      prey = Enum.find_value(neighbors, fn neighbor_hex ->
        Enum.find(Map.values(agents), fn agent ->
          Map.get(agent, :hex) == neighbor_hex and
          Map.get(agent, :species) == :forager and
          Map.get(agent, :alive, true)
        end)
      end)

      agent_state = Map.update(agent_state, :attacks, 0, &(&1 + 1))

      case prey do
        nil ->
          {agent_state, env_state}

        prey_agent ->
          prey_energy = Map.get(prey_agent, :energy, 0)
          new_prey_energy = prey_energy - attack_damage

          if new_prey_energy <= 0 do
            # Kill!
            prey_id = Map.get(prey_agent, :id)
            killed_prey = %{prey_agent | energy: 0, alive: false}

            # Add corpse
            corpses = Map.get(env_state, :corpses, %{})
            corpse_hex = Map.get(prey_agent, :hex)
            new_corpses = Map.put(corpses, corpse_hex, %{energy: prey_energy, decay: 50})

            updated_agent = %{agent_state |
              kills: Map.get(agent_state, :kills, 0) + 1,
              energy_from_kills: Map.get(agent_state, :energy_from_kills, 0) + kill_energy,
              energy: min(Map.get(agent_state, :energy, 0) + kill_energy, Map.get(agent_state, :max_energy, 400.0))
            }

            updated_env = env_state
            |> put_in([:agents, prey_id], killed_prey)
            |> Map.put(:corpses, new_corpses)

            {updated_agent, updated_env}
          else
            # Damage but not kill
            prey_id = Map.get(prey_agent, :id)
            damaged_prey = %{prey_agent | energy: new_prey_energy}
            updated_env = put_in(env_state, [:agents, prey_id], damaged_prey)
            {agent_state, updated_env}
          end
      end
    else
      {agent_state, env_state}
    end
  end

  defp apply_consume(action, agent_state, env_state) do
    consuming = Map.get(action, :active, false) and Map.get(action, :type) == :consume

    if consuming do
      hex = Map.get(agent_state, :hex)
      corpses = Map.get(env_state, :corpses, %{})

      case Map.get(corpses, hex) do
        nil ->
          {agent_state, env_state}

        corpse ->
          energy_gain = Map.get(corpse, :energy, 0) * 0.5  # Get 50% of corpse energy
          max_energy = Map.get(agent_state, :max_energy, 400.0)

          updated_agent = %{agent_state |
            energy: min(Map.get(agent_state, :energy, 0) + energy_gain, max_energy),
            energy_from_kills: Map.get(agent_state, :energy_from_kills, 0) + energy_gain
          }

          updated_env = Map.put(env_state, :corpses, Map.delete(corpses, hex))
          {updated_agent, updated_env}
      end
    else
      {agent_state, env_state}
    end
  end

  defp handle_hunt(predator, prey, env_state) do
    # Check if adjacent
    pred_hex = Map.get(predator, :hex)
    prey_hex = Map.get(prey, :hex)

    if Hex.distance(pred_hex, prey_hex) <= 1 do
      # Predator can attack
      config = get_species_config(:predator, env_state)
      damage = Map.get(config, :attack_damage, 60.0)
      prey_energy = Map.get(prey, :energy, 0) - damage

      if prey_energy <= 0 do
        # Kill
        kill_energy = Map.get(config, :kill_energy_gain, 80.0)
        new_predator = %{predator |
          kills: Map.get(predator, :kills, 0) + 1,
          energy: Map.get(predator, :energy, 0) + kill_energy
        }
        new_prey = %{prey | energy: 0, alive: false}
        {:ok, new_predator, new_prey, env_state}
      else
        new_prey = %{prey | energy: prey_energy}
        {:ok, predator, new_prey, env_state}
      end
    else
      {:ok, predator, prey, env_state}
    end
  end

  defp handle_competition(agent1, agent2, env_state) do
    # Same species competition - push away from resources
    {:ok, agent1, agent2, env_state}
  end

  defp spawn_initial_food(walls, arena_radius, count) do
    Enum.reduce(1..count, %{}, fn _, acc ->
      case Hex.random_open_hex(arena_radius, walls) do
        nil -> acc
        hex -> Map.put(acc, hex, %{energy: 20.0})
      end
    end)
  end

  defp maybe_spawn_food(env_state) do
    food = Map.get(env_state, :food, %{})
    max_food = Map.get(env_state, :max_food, @default_max_food)
    spawn_rate = Map.get(env_state, :food_spawn_rate, @default_food_spawn_rate)
    walls = Map.get(env_state, :walls, MapSet.new())
    arena_radius = Map.get(env_state, :arena_radius, @default_arena_radius)

    if map_size(food) < max_food and :rand.uniform() < spawn_rate do
      case Hex.random_open_hex(arena_radius, walls) do
        nil -> env_state
        hex -> Map.put(env_state, :food, Map.put(food, hex, %{energy: 20.0}))
      end
    else
      env_state
    end
  end

  defp decay_corpses(env_state) do
    corpses = Map.get(env_state, :corpses, %{})

    new_corpses = corpses
    |> Enum.map(fn {hex, corpse} ->
      decay = Map.get(corpse, :decay, 0) - 1
      {hex, %{corpse | decay: decay}}
    end)
    |> Enum.filter(fn {_hex, corpse} -> Map.get(corpse, :decay, 0) > 0 end)
    |> Map.new()

    Map.put(env_state, :corpses, new_corpses)
  end
end
