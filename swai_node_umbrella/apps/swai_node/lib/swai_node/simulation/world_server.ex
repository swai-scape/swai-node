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
  alias SwaiNode.Domain.DomainBridge
  alias SwaiNode.Geo.RoadNetwork
  alias SwaiNode.Worlds

  @pubsub SwaiNode.PubSub
  @topic "world:state"

  # Simulation constants - balanced for selection pressure
  # TODO: Wire to ecological_silo for dynamic tuning
  @move_cost 0.05  # ~2000 ticks to starve - more time to learn food-seeking
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

    # Get geo config for coordinate conversion
    geo_config = Application.get_env(:swai_node, :geo, [])
    origin_lat = Keyword.get(geo_config, :latitude, 52.5347)
    origin_lon = Keyword.get(geo_config, :longitude, 17.5828)

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
      stats: %{births: 0, deaths: 0, food_eaten: 0, attacks: 0, kills: 0, encounters: 0, peaceful_encounters: 0, diplomatic_successes: 0},
      # LC Silo integration
      prev_best_fitness: 0.0,
      silo_update_tick: 0,
      # Species tracking
      species_info: %{},
      species_update_tick: 0,
      # Geo origin for coordinate conversion
      origin_lat: origin_lat,
      origin_lon: origin_lon
    }

    # Initialize world asynchronously
    send(self(), :init_world)

    {:ok, state}
  end

  @impl true
  def handle_info(:init_world, state) do
    {:ok, world} = Worlds.get_or_create_default_world()
    state = %{state | world_id: world.id}

    # Wait for road network to load (with timeout)
    wait_for_road_network(50, 100)

    # Spawn initial population
    state = spawn_initial_population(state)

    # Spawn initial food
    state = spawn_initial_food(state)

    road_status = if RoadNetwork.loaded?(), do: "with roads", else: "without roads"
    Logger.info("[WorldServer] Initialized world #{world.id} with #{map_size(state.agents)} agents (#{road_status})")

    {:noreply, state}
  end

  # Wait for road network to load with retries
  defp wait_for_road_network(0, _delay), do: :ok
  defp wait_for_road_network(retries, delay) do
    if RoadNetwork.loaded?() do
      :ok
    else
      Process.sleep(delay)
      wait_for_road_network(retries - 1, delay)
    end
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
      stats: %{births: 0, deaths: 0, food_eaten: 0, attacks: 0, kills: 0, encounters: 0, peaceful_encounters: 0, diplomatic_successes: 0},
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
      total_kills: state.stats.kills,
      # Social/diplomacy stats
      total_encounters: state.stats.encounters,
      total_peaceful_encounters: state.stats.peaceful_encounters,
      total_diplomatic_successes: state.stats.diplomatic_successes,
      cooperation_rate: if(state.stats.encounters > 0, do: state.stats.peaceful_encounters / state.stats.encounters, else: 0.0),
      diplomacy_rate: if(state.stats.peaceful_encounters > 0, do: state.stats.diplomatic_successes / state.stats.peaceful_encounters, else: 0.0)
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
    |> handle_encounters()  # Track social interactions for diplomacy/cooperation
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

    # Emit domain signals to silos
    emit_domain_signals(state, best_fitness)

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

  # Emit domain signals to macula-neuroevolution silos
  defp emit_domain_signals(state, best_fitness) do
    # Build world state map for DomainBridge
    world_state = %{
      agents: state.agents,
      food: state.food,
      config: state.config,
      stats: state.stats
    }

    # Build metrics for stagnation detection
    metrics = %{
      prev_best_fitness: state.prev_best_fitness,
      best_fitness: best_fitness
    }

    # Emit signals via DomainBridge
    signals = DomainBridge.emit_signals(world_state, metrics)

    # Route to silos (if signal_router is available)
    try do
      :signal_router.route(signals)
    rescue
      # signal_router may not be running in all environments
      _error -> :ok
    catch
      :exit, _ -> :ok
    end
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
        updated = update_single_agent(agent, other_agents, state.food, world_size, state)
        {id, updated}
      end)
      |> Map.new()

    %{state | agents: updated_agents}
  end

  # Base movement speed in meters per tick
  @base_speed 3.0

  defp update_single_agent(agent, other_agents, food, world_size, state) do
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

    # Apply road-constrained movement
    agent = apply_road_movement(agent, actions, world_size, state)

    # Update energy (movement cost)
    new_energy = agent.energy - @move_cost

    %{agent |
      energy: new_energy,
      age: agent.age + 1,
      fitness: agent.fitness + 1,
      wants_eat: actions.eat,
      wants_reproduce: actions.reproduce,
      signal: actions.signal,
      wants_attack: actions.attack
    }
  end

  # Road-constrained movement: agents follow paths along roads
  defp apply_road_movement(agent, actions, world_size, state) do
    %{config: config} = state
    # Get geo origin (with defaults for backward compatibility)
    origin_lat = Map.get(state, :origin_lat, 52.5347)
    origin_lon = Map.get(state, :origin_lon, 17.5828)
    {width, height} = world_size

    # Get or create path
    agent = ensure_path(agent)

    # If still no path (road network not loaded), fall back to free movement
    case agent.path do
      [] ->
        apply_free_movement(agent, actions, width, height)

      [{next_lat, next_lon} | _rest] ->
        # Convert next waypoint to world coordinates
        {target_x, target_y} = lat_lon_to_world(next_lat, next_lon, config, origin_lat, origin_lon)

        # Calculate direction to next waypoint
        dx = target_x - agent.x
        dy = target_y - agent.y
        dist = :math.sqrt(dx * dx + dy * dy)

        # Speed controlled by neural network output (0 to max)
        move_speed = actions.move * @base_speed

        if dist < move_speed do
          # Reached waypoint - advance to next
          [_reached | remaining_path] = agent.path

          # Update road_node to the one we just reached
          new_road_node = RoadNetwork.find_nearest_node(next_lat, next_lon) || agent.road_node

          case remaining_path do
            [] ->
              # Path complete - pick new destination
              %{agent |
                x: target_x,
                y: target_y,
                direction: :math.atan2(dy, dx),
                path: [],
                target_node: nil,
                road_node: new_road_node
              }

            _ ->
              %{agent |
                x: target_x,
                y: target_y,
                direction: :math.atan2(dy, dx),
                path: remaining_path,
                road_node: new_road_node
              }
          end
        else
          # Move toward waypoint
          ratio = move_speed / dist
          new_x = agent.x + dx * ratio
          new_y = agent.y + dy * ratio

          %{agent |
            x: new_x,
            y: new_y,
            direction: :math.atan2(dy, dx)
          }
        end
    end
  end

  # Ensure agent has a path - if not, generate one
  defp ensure_path(%{path: [_ | _]} = agent), do: agent
  defp ensure_path(%{road_node: nil} = agent), do: agent
  defp ensure_path(agent) do
    # Pick a random destination node and find path
    case RoadNetwork.random_node() do
      nil ->
        agent

      target_node when target_node == agent.road_node ->
        # Same node, try again with different target
        case RoadNetwork.random_node() do
          nil -> agent
          ^target_node -> agent
          new_target -> find_and_set_path(agent, new_target)
        end

      target_node ->
        find_and_set_path(agent, target_node)
    end
  end

  defp find_and_set_path(agent, target_node) do
    case RoadNetwork.find_path(agent.road_node, target_node) do
      {:ok, path} when path != [] ->
        %{agent | target_node: target_node, path: path}

      _ ->
        # No path found, keep agent stationary until next tick
        agent
    end
  end

  # Fallback free movement when road network not available
  defp apply_free_movement(agent, actions, _width, _height) do
    new_direction = agent.direction + actions.turn * 0.1
    move_speed = actions.move * @base_speed

    new_x = agent.x + :math.cos(new_direction) * move_speed
    new_y = agent.y + :math.sin(new_direction) * move_speed

    %{agent | x: new_x, y: new_y, direction: new_direction}
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

  # Social proximity threshold for encounter tracking
  @encounter_range 50.0
  @high_signal_threshold 0.7

  # Track social encounters: proximity events, peaceful encounters, diplomatic successes
  # This enables cooperation and diplomacy to evolve by rewarding peaceful behavior
  defp handle_encounters(state) do
    agents = state.agents
    agent_list = Map.to_list(agents)

    # Find all pairs within encounter range
    {encounters, peaceful, diplomatic, updated_agents} =
      agent_list
      |> Enum.with_index()
      |> Enum.reduce({0, 0, 0, agents}, fn {{id1, agent1}, idx}, {enc, peace, diplo, acc_agents} ->
        # Check against all agents after this one (avoid double counting)
        nearby = agent_list
          |> Enum.drop(idx + 1)
          |> Enum.filter(fn {_id2, agent2} ->
            distance = :math.sqrt(:math.pow(agent1.x - agent2.x, 2) + :math.pow(agent1.y - agent2.y, 2))
            distance < @encounter_range
          end)

        Enum.reduce(nearby, {enc, peace, diplo, acc_agents}, fn {id2, agent2}, {e, p, d, agents_acc} ->
          # This is an encounter
          new_e = e + 1

          a1_wants_attack = Map.get(agent1, :wants_attack, false)
          a2_wants_attack = Map.get(agent2, :wants_attack, false)

          if not a1_wants_attack and not a2_wants_attack do
            # Peaceful encounter - both agents chose not to attack
            new_p = p + 1

            # Update per-agent peaceful encounter counts
            updated1 = Map.update(agents_acc[id1], :peaceful_encounters, 1, &(&1 + 1))
            updated2 = Map.update(agents_acc[id2], :peaceful_encounters, 1, &(&1 + 1))
            agents_acc = agents_acc |> Map.put(id1, updated1) |> Map.put(id2, updated2)

            # Check for diplomatic success (high signal from either party)
            a1_signal = Map.get(agent1, :signal, 0.5)
            a2_signal = Map.get(agent2, :signal, 0.5)

            if a1_signal > @high_signal_threshold or a2_signal > @high_signal_threshold do
              # Diplomatic success: signaled and didn't attack
              new_d = d + 1

              # Update per-agent diplomatic success counts
              updated1 = Map.update(agents_acc[id1], :diplomatic_successes, 1, &(&1 + 1))
              updated2 = Map.update(agents_acc[id2], :diplomatic_successes, 1, &(&1 + 1))
              agents_acc = agents_acc |> Map.put(id1, updated1) |> Map.put(id2, updated2)

              {new_e, new_p, new_d, agents_acc}
            else
              {new_e, new_p, d, agents_acc}
            end
          else
            {new_e, p, d, agents_acc}
          end
        end)
      end)

    stats = %{state.stats |
      encounters: state.stats.encounters + encounters,
      peaceful_encounters: state.stats.peaceful_encounters + peaceful,
      diplomatic_successes: state.stats.diplomatic_successes + diplomatic
    }

    %{state | agents: updated_agents, stats: stats}
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

    # Get geo config for coordinate conversion
    geo_config = Application.get_env(:swai_node, :geo, [])
    origin_lat = Keyword.get(geo_config, :latitude, 52.5347)
    origin_lon = Keyword.get(geo_config, :longitude, 17.5828)

    # Spawn near parent's road node, or with offset if no road data
    {x, y, road_node} =
      case parent[:road_node] do
        nil ->
          # No road data, spawn with random offset from parent
          offset_x = (:rand.uniform() - 0.5) * 20
          offset_y = (:rand.uniform() - 0.5) * 20
          {parent.x + offset_x, parent.y + offset_y, nil}

        parent_node ->
          case RoadNetwork.random_road_point_near_node(parent_node, 20) do
            {lat, lon, node_id} ->
              {x, y} = lat_lon_to_world(lat, lon, config, origin_lat, origin_lon)
              {x, y, node_id}

            nil ->
              # Fall back to offset from parent
              offset_x = (:rand.uniform() - 0.5) * 20
              offset_y = (:rand.uniform() - 0.5) * 20
              {parent.x + offset_x, parent.y + offset_y, parent_node}
          end
      end

    %{
      id: nil,  # Will be assigned
      x: x,
      y: y,
      direction: :rand.uniform() * 2 * :math.pi(),
      energy: 100.0,
      age: 0,
      generation: parent.generation + 1,
      fitness: 0.0,
      food_eaten: 0,
      kills: 0,
      peaceful_encounters: 0,
      diplomatic_successes: 0,
      network: offspring_network,
      parent_id: parent.id,
      species_id: parent.species_id,
      wants_eat: false,
      wants_reproduce: false,
      wants_attack: false,
      signal: parent.signal,  # Inherit parent's signal initially
      road_node: road_node,
      target_node: nil,
      path: []
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
    origin_lat = Map.get(state, :origin_lat, 52.5347)
    origin_lon = Map.get(state, :origin_lon, 17.5828)

    # Spawn food based on spawn rate - only on streets
    new_food =
      if length(food) < config.max_food and :rand.uniform() < config.food_spawn_rate do
        case get_food_road_position(config, origin_lat, origin_lon) do
          {x, y} -> [{x, y, @food_energy} | food]
          nil -> food  # No road position available
        end
      else
        food
      end

    %{state | food: new_food}
  end

  # Get a random road position for food spawning - within 200m of origin
  defp get_food_road_position(config, origin_lat, origin_lon) do
    case RoadNetwork.random_road_point_near(origin_lat, origin_lon, 200) do
      {lat, lon, _node_id} ->
        lat_lon_to_world(lat, lon, config, origin_lat, origin_lon)

      nil ->
        # Road network not loaded, fall back to random
        x = :rand.uniform() * config.width
        y = :rand.uniform() * config.height
        {x, y}
    end
  end

  # =============================================================================
  # Initialization
  # =============================================================================

  defp spawn_initial_population(state) do
    %{config: config} = state

    # Get geo config for origin
    geo_config = Application.get_env(:swai_node, :geo, [])
    origin_lat = Keyword.get(geo_config, :latitude, 52.5347)
    origin_lon = Keyword.get(geo_config, :longitude, 17.5828)

    agents =
      1..config.starting_population
      |> Enum.map(fn id ->
        # Try to spawn on road near origin, fall back to random
        {x, y, road_node} = get_spawn_position_near_origin(config, origin_lat, origin_lon)

        agent = %{
          id: id,
          x: x,
          y: y,
          direction: :rand.uniform() * 2 * :math.pi(),
          energy: 100.0,
          age: 0,
          generation: 0,
          fitness: 0.0,
          food_eaten: 0,
          kills: 0,
          peaceful_encounters: 0,
          diplomatic_successes: 0,
          network: AgentBrain.create_network(),
          parent_id: nil,
          species_id: "gen0",
          wants_eat: false,
          wants_reproduce: false,
          wants_attack: false,
          signal: 0.5,  # Initial neutral signal
          road_node: road_node,  # Track which road node agent is near
          target_node: nil,  # Destination node for pathfinding
          path: []  # List of {lat, lon} waypoints to follow
        }
        {id, agent}
      end)
      |> Map.new()

    %{state |
      agents: agents,
      next_agent_id: config.starting_population + 1
    }
  end

  # Get spawn position near origin, using roads if available
  defp get_spawn_position_near_origin(config, origin_lat, origin_lon) do
    case RoadNetwork.random_road_point_near(origin_lat, origin_lon, 50) do
      {lat, lon, road_node} ->
        # Convert lat/lon to world x/y coordinates
        {x, y} = lat_lon_to_world(lat, lon, config, origin_lat, origin_lon)
        {x, y, road_node}

      nil ->
        # Road network not loaded, fall back to random position near center
        x = config.width / 2 + (:rand.uniform() - 0.5) * 100
        y = config.height / 2 + (:rand.uniform() - 0.5) * 100
        {x, y, nil}
    end
  end

  # Convert lat/lon to world coordinates (x, y in pixels)
  # Origin lat/lon maps to center of world (width/2, height/2)
  # 1 pixel = 1 meter
  # No clamping - agents can move anywhere on the road network
  defp lat_lon_to_world(lat, lon, config, origin_lat, origin_lon) do
    # Meters per degree
    meters_per_deg_lat = 111_320
    meters_per_deg_lon = 111_320 * :math.cos(origin_lat * :math.pi() / 180)

    # Offset from origin in meters
    offset_x = (lon - origin_lon) * meters_per_deg_lon
    offset_y = (origin_lat - lat) * meters_per_deg_lat  # Y inverted

    # Convert to world coordinates (origin at center)
    x = config.width / 2 + offset_x
    y = config.height / 2 + offset_y

    {x, y}
  end

  # Reverse: convert world x/y back to lat/lon for frontend rendering
  defp world_to_lat_lon(x, y, config, origin_lat, origin_lon) do
    meters_per_deg_lat = 111_320
    meters_per_deg_lon = 111_320 * :math.cos(origin_lat * :math.pi() / 180)

    # Offset from center in meters
    offset_x = x - config.width / 2
    offset_y = y - config.height / 2

    # Convert back to lat/lon
    lon = origin_lon + offset_x / meters_per_deg_lon
    lat = origin_lat - offset_y / meters_per_deg_lat  # Y inverted

    {lat, lon}
  end

  defp spawn_initial_food(state) do
    %{config: config} = state
    origin_lat = Map.get(state, :origin_lat, 52.5347)
    origin_lon = Map.get(state, :origin_lon, 17.5828)

    # Spawn initial food only on streets
    food =
      1..config.max_food
      |> Enum.map(fn _ ->
        {x, y} = get_food_road_position(config, origin_lat, origin_lon)
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
    # Throttle broadcasts to avoid overwhelming the browser
    # Realtime: every 5 ticks (~6fps), Fast: every 50 ticks
    should_broadcast = case state.mode do
      :realtime -> rem(state.tick, 5) == 0
      :fast -> rem(state.tick, 50) == 0
    end

    if should_broadcast do
      agents_list = Map.values(state.agents)
      {best_fit, avg_fit} = calculate_fitness_stats(agents_list)

      # Get species stats
      species_stats = SpeciesTracker.get_species_stats(state.species_info)
      diversity = SpeciesTracker.diversity_index(state.species_info)

      # Calculate behavioral types
      behavioral_types = calculate_behavioral_types(agents_list)

      render_state = %{
        agents: Enum.map(agents_list, &agent_to_render(&1, state)),
        food: Enum.map(state.food, &food_to_render(&1, state)),
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
          encounters: state.stats.encounters,
          peaceful_encounters: state.stats.peaceful_encounters,
          diplomatic_successes: state.stats.diplomatic_successes,
          best_fitness: best_fit,
          avg_fitness: avg_fit,
          cooperation_rate: calculate_rate(state.stats.peaceful_encounters, state.stats.encounters),
          diplomacy_rate: calculate_rate(state.stats.diplomatic_successes, state.stats.peaceful_encounters)
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

  defp agent_to_render(agent, state) do
    {lat, lon} = world_to_lat_lon(agent.x, agent.y, state.config, state.origin_lat, state.origin_lon)

    %{
      id: agent.id,
      x: agent.x,
      y: agent.y,
      lat: lat,
      lon: lon,
      direction: agent.direction,
      energy: agent.energy,
      fitness: agent.fitness,
      generation: agent.generation,
      age: Map.get(agent, :age, 0),
      signal: Map.get(agent, :signal, 0.5),
      species_id: Map.get(agent, :species_id, "gen0"),
      wants_attack: Map.get(agent, :wants_attack, false),
      kills: Map.get(agent, :kills, 0),
      food_eaten: Map.get(agent, :food_eaten, 0)
    }
  end

  defp food_to_render({x, y, energy}, state) do
    {lat, lon} = world_to_lat_lon(x, y, state.config, state.origin_lat, state.origin_lon)

    %{
      x: x,
      y: y,
      lat: lat,
      lon: lon,
      energy: energy
    }
  end

  defp safe_avg([]), do: 0.0
  defp safe_avg(list), do: Enum.sum(list) / length(list)

  defp calculate_rate(_numerator, 0), do: 0.0
  defp calculate_rate(numerator, denominator), do: numerator / denominator
end
