defmodule SwaiNode.Simulation.WorldServer do
  @moduledoc """
  Main simulation server for a world.

  Manages:
  - The simulation loop (tick-based)
  - Agent positions, energy, and actions
  - Food spawning and consumption
  - Agent reproduction and death
  - Broadcasting state updates via PubSub
  """

  use GenServer
  require Logger

  alias SwaiNode.Simulation.{AgentBrain, SiloIntegration, SpeciesTracker, Vision}
  alias SwaiNode.Worlds

  @pubsub SwaiNode.PubSub
  @topic "world:state"

  # Simulation constants - balanced for selection pressure
  @move_cost 0.12  # ~830 ticks to starve - reasonable pressure
  @eat_range 18.0  # Must get close to eat - forces navigation
  @eat_gain 40.0   # Good reward for eating
  @max_energy 200.0
  @reproduction_threshold 130.0  # Need to eat 2-3 times to reproduce
  @reproduction_cost 60.0  # Meaningful cost
  @agent_radius 5.0
  @food_energy 20.0

  # Predator-prey constants
  @attack_range 15.0         # Must be close to attack
  @attack_cost 2.0           # Energy cost to attempt attack
  @attack_energy_transfer 0.6  # Gain 60% of victim's energy
  @smell_range 60.0          # Range for smell detection
  @max_smell_count 10.0      # Normalize smell by this max
  @prey_energy_threshold 100.0  # Agents below this are "prey-like"

  # Default configuration
  @default_config %{
    width: 800,
    height: 600,
    starting_population: 80,   # Fewer agents = less crowded
    food_spawn_rate: 0.8,      # Spawn food frequently
    max_food: 150,             # Plenty of visible food
    mutation_rate: 0.1,
    mutation_strength: 0.3,
    tick_interval_realtime: 33,
    tick_interval_fast: 1
  }

  # =============================================================================
  # Client API
  # =============================================================================

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Start or resume the simulation"
  def play(server \\ __MODULE__), do: GenServer.call(server, :play)

  @doc "Pause the simulation"
  def pause(server \\ __MODULE__), do: GenServer.call(server, :pause)

  @doc "Toggle between realtime and fast mode"
  def set_mode(server \\ __MODULE__, mode) when mode in [:realtime, :fast] do
    GenServer.call(server, {:set_mode, mode})
  end

  @doc "Reset the world (clear all agents, respawn)"
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @doc "Get current world state for rendering"
  def get_state(server \\ __MODULE__), do: GenServer.call(server, :get_state)

  @doc "Get statistics"
  def get_stats(server \\ __MODULE__), do: GenServer.call(server, :get_stats)

  # =============================================================================
  # Server Callbacks
  # =============================================================================

  @impl true
  def init(opts) do
    config = Map.merge(@default_config, Map.new(opts))

    state = %{
      world_id: nil,
      config: config,
      agents: %{},
      food: [],
      tick: 0,
      generation: 0,
      mode: :realtime,
      running: false,
      next_agent_id: 1,
      stats: %{births: 0, deaths: 0, food_eaten: 0, attacks: 0, kills: 0},
      # LC Silo integration
      prev_best_fitness: 0.0,
      silo_update_tick: 0,
      # Species tracking
      species_info: %{},
      species_update_tick: 0
    }

    # Initialize world asynchronously
    send(self(), :init_world)

    {:ok, state}
  end

  @impl true
  def handle_info(:init_world, state) do
    {:ok, world} = Worlds.get_or_create_default_world()
    state = %{state | world_id: world.id}

    # Spawn initial population
    state = spawn_initial_population(state)

    # Spawn initial food
    state = spawn_initial_food(state)

    Logger.info("[WorldServer] Initialized world #{world.id} with #{map_size(state.agents)} agents")

    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, %{running: false} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = simulation_step(state)

    # Schedule next tick
    schedule_tick(state)

    # Broadcast state update
    broadcast_state(state)

    {:noreply, state}
  end

  @impl true
  def handle_call(:play, _from, state) do
    state = %{state | running: true}
    schedule_tick(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:pause, _from, state) do
    {:reply, :ok, %{state | running: false}}
  end

  @impl true
  def handle_call({:set_mode, mode}, _from, state) do
    {:reply, :ok, %{state | mode: mode}}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    # Reset config to defaults (clears any silo adjustments)
    config = Map.merge(@default_config, %{
      width: state.config.width,
      height: state.config.height
    })

    # Clear agents and food
    state = %{state |
      config: config,
      agents: %{},
      food: [],
      tick: 0,
      generation: 0,
      next_agent_id: 1,
      stats: %{births: 0, deaths: 0, food_eaten: 0, attacks: 0, kills: 0},
      prev_best_fitness: 0.0,
      silo_update_tick: 0,
      species_info: %{},
      species_update_tick: 0
    }

    # Respawn
    state = spawn_initial_population(state)
    state = spawn_initial_food(state)

    broadcast_state(state)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    render_state = %{
      agents: Map.values(state.agents),
      food: state.food,
      tick: state.tick,
      generation: state.generation,
      running: state.running,
      mode: state.mode,
      config: %{
        width: state.config.width,
        height: state.config.height
      }
    }
    {:reply, render_state, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    agent_list = Map.values(state.agents)
    fitness_values = Enum.map(agent_list, & &1.fitness)

    stats = %{
      tick: state.tick,
      generation: state.generation,
      population: length(agent_list),
      food_count: length(state.food),
      best_fitness: Enum.max(fitness_values, fn -> 0 end),
      avg_fitness: safe_avg(fitness_values),
      total_births: state.stats.births,
      total_deaths: state.stats.deaths,
      total_food_eaten: state.stats.food_eaten,
      total_attacks: state.stats.attacks,
      total_kills: state.stats.kills
    }

    {:reply, stats, state}
  end

  # =============================================================================
  # Simulation Logic
  # =============================================================================

  defp simulation_step(state) do
    state
    |> increment_tick()
    |> update_agents()
    |> handle_attacks()
    |> handle_eating()
    |> handle_reproduction()
    |> handle_deaths()
    |> spawn_food()
    |> maybe_update_silo()
    |> maybe_update_species()
  end

  # Update task_silo every 100 ticks to get adaptive hyperparameters
  @silo_update_interval 100

  defp maybe_update_silo(state) do
    ticks_since_update = state.tick - state.silo_update_tick

    if ticks_since_update >= @silo_update_interval do
      update_silo(state)
    else
      state
    end
  end

  defp update_silo(state) do
    agent_list = Map.values(state.agents)
    fitness_values = Enum.map(agent_list, & &1.fitness)

    best_fitness = Enum.max(fitness_values, fn -> 0.0 end)
    avg_fitness = safe_avg(fitness_values)
    improvement = best_fitness - state.prev_best_fitness

    # Build stats for task_silo
    stats = %{
      best_fitness: best_fitness,
      avg_fitness: avg_fitness,
      improvement: improvement,
      total_evaluations: state.tick,
      generation: state.generation,
      population_size: length(agent_list)
    }

    # Get recommendations from task_silo (includes update_stats internally)
    recommendations = SiloIntegration.get_recommendations(stats)

    # Extract mutation parameters (task_silo returns atom keys)
    mutation_rate = Map.get(recommendations, :mutation_rate, state.config.mutation_rate)
    mutation_strength = Map.get(recommendations, :mutation_strength, state.config.mutation_strength)

    # Log when parameters change significantly
    if abs(mutation_rate - state.config.mutation_rate) > 0.01 do
      Logger.info("[WorldServer] task_silo adjusted mutation_rate: #{Float.round(mutation_rate, 3)}")
    end

    # Update config with new parameters
    updated_config = %{state.config |
      mutation_rate: mutation_rate,
      mutation_strength: mutation_strength
    }

    %{state |
      config: updated_config,
      prev_best_fitness: best_fitness,
      silo_update_tick: state.tick
    }
  end

  # Update species every 200 ticks (less frequent than silo)
  @species_update_interval 200

  defp maybe_update_species(state) do
    ticks_since_update = state.tick - state.species_update_tick

    if ticks_since_update >= @species_update_interval and map_size(state.agents) > 0 do
      update_species(state)
    else
      state
    end
  end

  defp update_species(state) do
    # Assign species based on network similarity
    {updated_agents, species_info} = SpeciesTracker.assign_species(state.agents, 0.4)

    %{state |
      agents: updated_agents,
      species_info: species_info,
      species_update_tick: state.tick
    }
  end

  defp increment_tick(state) do
    %{state | tick: state.tick + 1}
  end

  defp update_agents(state) do
    %{config: config} = state
    world_size = {config.width, config.height}

    updated_agents =
      state.agents
      |> Enum.map(fn {id, agent} ->
        other_agents = state.agents |> Map.delete(id) |> Map.values()
        updated = update_single_agent(agent, other_agents, state.food, world_size, config)
        {id, updated}
      end)
      |> Map.new()

    %{state | agents: updated_agents}
  end

  defp update_single_agent(agent, other_agents, food, world_size, _config) do
    # Cast vision rays
    vision = Vision.cast_rays(agent, other_agents, food, world_size)

    # Calculate hearing inputs (signals from 4 nearest agents)
    hearing = calculate_hearing(agent, other_agents)

    # Calculate smell inputs (food density, prey density, threat density)
    smell = calculate_smell(agent, other_agents, food)

    # Build inputs and evaluate network
    inputs = AgentBrain.build_inputs(agent, vision, hearing, smell)
    outputs = AgentBrain.evaluate(agent.network, inputs)
    actions = AgentBrain.parse_outputs(outputs)

    # Apply movement
    {width, height} = world_size
    new_direction = agent.direction + actions.turn * 0.1
    move_speed = actions.move * 3.0

    new_x = agent.x + :math.cos(new_direction) * move_speed
    new_y = agent.y + :math.sin(new_direction) * move_speed

    # Clamp to world bounds
    new_x = max(@agent_radius, min(width - @agent_radius, new_x))
    new_y = max(@agent_radius, min(height - @agent_radius, new_y))

    # Update energy (movement cost)
    new_energy = agent.energy - @move_cost

    %{agent |
      x: new_x,
      y: new_y,
      direction: new_direction,
      energy: new_energy,
      age: agent.age + 1,
      fitness: agent.fitness + 1,
      wants_eat: actions.eat,
      wants_reproduce: actions.reproduce,
      signal: actions.signal,
      wants_attack: actions.attack
    }
  end

  # Calculate hearing inputs: signals from the 4 nearest agents
  @hearing_range 80.0  # Can hear agents within this range

  defp calculate_hearing(agent, other_agents) do
    # Find nearby agents sorted by distance
    nearby_signals =
      other_agents
      |> Enum.map(fn other ->
        dx = other.x - agent.x
        dy = other.y - agent.y
        distance = :math.sqrt(dx * dx + dy * dy)
        {distance, Map.get(other, :signal, 0.5)}
      end)
      |> Enum.filter(fn {dist, _} -> dist < @hearing_range end)
      |> Enum.sort_by(fn {dist, _} -> dist end)
      |> Enum.take(4)
      |> Enum.map(fn {_dist, signal} -> signal end)

    # Pad with 0.0 if fewer than 4 nearby agents
    nearby_signals ++ List.duplicate(0.0, 4 - length(nearby_signals))
  end

  # Calculate smell inputs: nearby food, prey-like agents, threat-like agents
  defp calculate_smell(agent, other_agents, food) do
    # Count food within smell range
    food_count =
      food
      |> Enum.count(fn {fx, fy, _} ->
        distance = :math.sqrt(:math.pow(agent.x - fx, 2) + :math.pow(agent.y - fy, 2))
        distance < @smell_range
      end)

    # Count nearby agents and classify by energy level
    {prey_count, threat_count} =
      other_agents
      |> Enum.reduce({0, 0}, fn other, {prey, threat} ->
        distance = :math.sqrt(:math.pow(agent.x - other.x, 2) + :math.pow(agent.y - other.y, 2))
        if distance < @smell_range do
          if other.energy < @prey_energy_threshold do
            {prey + 1, threat}
          else
            {prey, threat + 1}
          end
        else
          {prey, threat}
        end
      end)

    # Normalize to 0-1 range
    [
      min(food_count / @max_smell_count, 1.0),
      min(prey_count / @max_smell_count, 1.0),
      min(threat_count / @max_smell_count, 1.0)
    ]
  end

  # Handle agent attacks - agents can eat other agents
  defp handle_attacks(state) do
    agents = state.agents

    # Find all agents wanting to attack
    attackers =
      agents
      |> Enum.filter(fn {_id, agent} -> Map.get(agent, :wants_attack, false) end)
      |> Enum.map(fn {id, agent} -> {id, agent} end)

    # Process attacks - attacker with highest energy wins conflicts
    {updated_agents, kills, attacks} =
      Enum.reduce(attackers, {agents, 0, 0}, fn {attacker_id, _attacker}, {acc_agents, acc_kills, acc_attacks} ->
        # Skip if attacker was already killed
        case Map.get(acc_agents, attacker_id) do
          nil ->
            {acc_agents, acc_kills, acc_attacks}

          current_attacker ->
            # Find nearest victim within attack range
            victim =
              acc_agents
              |> Enum.reject(fn {id, _} -> id == attacker_id end)
              |> Enum.map(fn {id, other} ->
                distance = :math.sqrt(:math.pow(current_attacker.x - other.x, 2) + :math.pow(current_attacker.y - other.y, 2))
                {id, other, distance}
              end)
              |> Enum.filter(fn {_, _, dist} -> dist < @attack_range end)
              |> Enum.min_by(fn {_, _, dist} -> dist end, fn -> nil end)

            # Deduct attack cost from attacker
            attacker_after_cost = %{current_attacker | energy: current_attacker.energy - @attack_cost}
            acc_agents = Map.put(acc_agents, attacker_id, attacker_after_cost)

            case victim do
              nil ->
                # No victim in range, just cost energy
                {acc_agents, acc_kills, acc_attacks + 1}

              {victim_id, victim_agent, _distance} ->
                # Successful attack! Transfer energy and kill victim
                energy_gained = victim_agent.energy * @attack_energy_transfer
                updated_attacker = %{attacker_after_cost |
                  energy: min(attacker_after_cost.energy + energy_gained, @max_energy),
                  fitness: attacker_after_cost.fitness + 100,  # Big fitness bonus for kill
                  kills: Map.get(attacker_after_cost, :kills, 0) + 1
                }

                acc_agents = acc_agents
                             |> Map.put(attacker_id, updated_attacker)
                             |> Map.delete(victim_id)

                {acc_agents, acc_kills + 1, acc_attacks + 1}
            end
        end
      end)

    stats = %{state.stats |
      attacks: state.stats.attacks + attacks,
      kills: state.stats.kills + kills
    }

    %{state | agents: updated_agents, stats: stats}
  end

  defp handle_eating(state) do
    # Eating is automatic when near food - no neural network decision needed
    # Evolution will select for agents that navigate toward food
    {agents, food, eaten_count} =
      Enum.reduce(state.agents, {%{}, state.food, 0}, fn {id, agent}, {acc_agents, acc_food, count} ->
        case find_nearby_food(agent, acc_food) do
          nil ->
            {Map.put(acc_agents, id, agent), acc_food, count}

          {_food_item, remaining_food} ->
            updated_agent = %{agent |
              energy: min(agent.energy + @eat_gain, @max_energy),
              food_eaten: agent.food_eaten + 1,
              fitness: agent.fitness + 50
            }
            {Map.put(acc_agents, id, updated_agent), remaining_food, count + 1}
        end
      end)

    stats = %{state.stats | food_eaten: state.stats.food_eaten + eaten_count}
    %{state | agents: agents, food: food, stats: stats}
  end

  defp find_nearby_food(agent, food) do
    Enum.find_value(food, fn {fx, fy, _} = food_item ->
      distance = :math.sqrt(:math.pow(agent.x - fx, 2) + :math.pow(agent.y - fy, 2))
      if distance < @eat_range do
        {food_item, List.delete(food, food_item)}
      end
    end)
  end

  defp handle_reproduction(state) do
    # Reproduction is automatic when energy is high enough
    # This creates natural evolutionary pressure - agents that find food reproduce
    {agents, new_agents, births} =
      Enum.reduce(state.agents, {%{}, [], 0}, fn {id, agent}, {acc, new_acc, births} ->
        if agent.energy > @reproduction_threshold do
          # Deduct reproduction cost from parent
          parent = %{agent | energy: agent.energy - @reproduction_cost}

          # Create offspring
          offspring = create_offspring(parent, state)

          {Map.put(acc, id, parent), [offspring | new_acc], births + 1}
        else
          {Map.put(acc, id, agent), new_acc, births}
        end
      end)

    # Add offspring to agents map and track max generation
    {final_agents, next_id, max_gen} =
      Enum.reduce(new_agents, {agents, state.next_agent_id, state.generation}, fn offspring, {acc, id, gen} ->
        offspring = %{offspring | id: id}
        new_gen = max(gen, offspring.generation)
        {Map.put(acc, id, offspring), id + 1, new_gen}
      end)

    stats = %{state.stats | births: state.stats.births + births}
    %{state | agents: final_agents, next_agent_id: next_id, stats: stats, generation: max_gen}
  end

  defp create_offspring(parent, state) do
    %{config: config} = state

    # Mutate parent's network
    offspring_network = AgentBrain.create_offspring(
      parent.network,
      config.mutation_rate,
      config.mutation_strength
    )

    # Spawn near parent with random offset
    offset_x = (:rand.uniform() - 0.5) * 20
    offset_y = (:rand.uniform() - 0.5) * 20

    %{
      id: nil,  # Will be assigned
      x: clamp(parent.x + offset_x, @agent_radius, config.width - @agent_radius),
      y: clamp(parent.y + offset_y, @agent_radius, config.height - @agent_radius),
      direction: :rand.uniform() * 2 * :math.pi(),
      energy: 100.0,
      age: 0,
      generation: parent.generation + 1,
      fitness: 0.0,
      food_eaten: 0,
      kills: 0,
      network: offspring_network,
      parent_id: parent.id,
      species_id: parent.species_id,
      wants_eat: false,
      wants_reproduce: false,
      wants_attack: false,
      signal: parent.signal  # Inherit parent's signal initially
    }
  end

  defp handle_deaths(state) do
    {alive, dead_count} =
      Enum.reduce(state.agents, {%{}, 0}, fn {id, agent}, {acc, deaths} ->
        if agent.energy <= 0 do
          {acc, deaths + 1}
        else
          {Map.put(acc, id, agent), deaths}
        end
      end)

    stats = %{state.stats | deaths: state.stats.deaths + dead_count}
    %{state | agents: alive, stats: stats}
  end

  defp spawn_food(state) do
    %{config: config, food: food} = state

    # Spawn food based on spawn rate
    new_food =
      if length(food) < config.max_food and :rand.uniform() < config.food_spawn_rate do
        x = :rand.uniform() * config.width
        y = :rand.uniform() * config.height
        [{x, y, @food_energy} | food]
      else
        food
      end

    %{state | food: new_food}
  end

  # =============================================================================
  # Initialization
  # =============================================================================

  defp spawn_initial_population(state) do
    %{config: config} = state

    agents =
      1..config.starting_population
      |> Enum.map(fn id ->
        agent = %{
          id: id,
          x: :rand.uniform() * config.width,
          y: :rand.uniform() * config.height,
          direction: :rand.uniform() * 2 * :math.pi(),
          energy: 100.0,
          age: 0,
          generation: 0,
          fitness: 0.0,
          food_eaten: 0,
          kills: 0,
          network: AgentBrain.create_network(),
          parent_id: nil,
          species_id: "gen0",
          wants_eat: false,
          wants_reproduce: false,
          wants_attack: false,
          signal: 0.5  # Initial neutral signal
        }
        {id, agent}
      end)
      |> Map.new()

    %{state |
      agents: agents,
      next_agent_id: config.starting_population + 1
    }
  end

  defp spawn_initial_food(state) do
    %{config: config} = state

    food =
      1..config.max_food
      |> Enum.map(fn _ ->
        x = :rand.uniform() * config.width
        y = :rand.uniform() * config.height
        {x, y, @food_energy}
      end)

    %{state | food: food}
  end

  # =============================================================================
  # Helpers
  # =============================================================================

  defp schedule_tick(state) do
    interval =
      case state.mode do
        :realtime -> state.config.tick_interval_realtime
        :fast -> state.config.tick_interval_fast
      end

    Process.send_after(self(), :tick, interval)
  end

  defp broadcast_state(state) do
    # Broadcast in realtime mode, or every 25 ticks in fast mode for UI responsiveness
    should_broadcast = state.mode == :realtime or rem(state.tick, 25) == 0

    if should_broadcast do
      agents_list = Map.values(state.agents)
      {best_fit, avg_fit} = calculate_fitness_stats(agents_list)

      # Get species stats
      species_stats = SpeciesTracker.get_species_stats(state.species_info)
      diversity = SpeciesTracker.diversity_index(state.species_info)

      # Calculate behavioral types
      behavioral_types = calculate_behavioral_types(agents_list)

      render_state = %{
        agents: Enum.map(agents_list, &agent_to_render/1),
        food: state.food,
        tick: state.tick,
        population: map_size(state.agents),
        running: state.running,
        mode: state.mode,
        generation: state.generation,
        # Include stats for dashboard
        stats: %{
          births: state.stats.births,
          deaths: state.stats.deaths,
          food_eaten: state.stats.food_eaten,
          attacks: state.stats.attacks,
          kills: state.stats.kills,
          best_fitness: best_fit,
          avg_fitness: avg_fit
        },
        # Species info
        species: species_stats,
        diversity: diversity,
        # Behavioral types (herbivore/omnivore/carnivore)
        behavioral_types: behavioral_types
      }

      Phoenix.PubSub.broadcast(@pubsub, @topic, {:world_update, render_state})
    end
  end

  defp calculate_behavioral_types(agents) do
    Enum.reduce(agents, %{herbivore: 0, omnivore: 0, carnivore: 0}, fn agent, acc ->
      kills = Map.get(agent, :kills, 0)
      food_eaten = Map.get(agent, :food_eaten, 0)

      cond do
        kills == 0 -> %{acc | herbivore: acc.herbivore + 1}
        kills > food_eaten -> %{acc | carnivore: acc.carnivore + 1}
        true -> %{acc | omnivore: acc.omnivore + 1}
      end
    end)
  end

  defp calculate_fitness_stats([]), do: {0.0, 0.0}
  defp calculate_fitness_stats(agents) do
    fitnesses = Enum.map(agents, & &1.fitness)
    best = Enum.max(fitnesses)
    avg = Enum.sum(fitnesses) / length(fitnesses)
    {best, Float.round(avg, 1)}
  end

  defp agent_to_render(agent) do
    %{
      id: agent.id,
      x: agent.x,
      y: agent.y,
      direction: agent.direction,
      energy: agent.energy,
      fitness: agent.fitness,
      generation: agent.generation,
      signal: Map.get(agent, :signal, 0.5),
      species_id: Map.get(agent, :species_id, "gen0"),
      wants_attack: Map.get(agent, :wants_attack, false),
      kills: Map.get(agent, :kills, 0)
    }
  end

  defp safe_avg([]), do: 0.0
  defp safe_avg(list), do: Enum.sum(list) / length(list)

  defp clamp(value, min_val, max_val) do
    value |> max(min_val) |> min(max_val)
  end
end
