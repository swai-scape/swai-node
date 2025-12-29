defmodule SwaiNode.Simulation.HexWorldServer do
  @moduledoc """
  Hex-based simulation server for agent evolution.

  Key differences from WorldServer:
  - Agents move on discrete hex grid (axial coordinates)
  - Movement is 6 directions or stay
  - Procedurally generated maze with walls
  - Walls block both movement and vision
  - No road network / geo coordinates
  """

  use GenServer
  require Logger

  alias SwaiNode.Simulation.{AgentBrain, Hex, HexMaze, HexVision, SiloIntegration, SpeciesTracker}
  alias SwaiNode.Training.TrainingServer
  alias SwaiNode.Domain.{Actuator, DomainBridge, Events}
  alias SwaiNode.Worlds

  @pubsub SwaiNode.PubSub
  @topic "world:state"

  # Fine-grained event topics (only meaningful state changes)
  @topic_agent_moved "agent:moved"
  @topic_agent_ate "agent:ate"
  @topic_agent_died "agent:died"
  @topic_agent_spawned "agent:spawned"

  # Simulation constants
  @move_cost 0.05
  @eat_gain 40.0
  @max_energy 200.0
  @reproduction_threshold 130.0
  @reproduction_cost 60.0
  @food_energy 20.0

  # Predator-prey constants
  @attack_cost 2.0
  @attack_energy_transfer 0.6
  @smell_range 5  # Hex distance
  @max_smell_count 10.0
  @prey_energy_threshold 100.0
  @hearing_range 4  # Hex distance

  # Default configuration - LARGER ARENA with smaller hexes
  @default_config %{
    arena_radius: 40,
    hex_size: 8,
    starting_population: 1,  # Single agent for debugging
    food_spawn_rate: 0.8,
    max_food: 150,
    mutation_rate: 0.1,
    mutation_strength: 0.3,
    tick_interval_realtime: 50,  # 50ms = 20fps for smoother movement
    tick_interval_fast: 10,
    wall_percent: 12,
    open_center_radius: 6
  }

  # Client API
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def play(server \\ __MODULE__), do: GenServer.call(server, :play)
  def pause(server \\ __MODULE__), do: GenServer.call(server, :pause)
  def set_mode(server \\ __MODULE__, mode) when mode in [:realtime, :fast] do
    GenServer.call(server, {:set_mode, mode})
  end
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)
  def get_state(server \\ __MODULE__), do: GenServer.call(server, :get_state)
  def get_stats(server \\ __MODULE__), do: GenServer.call(server, :get_stats)

  # Server Callbacks
  @impl true
  def init(opts) do
    config = Map.merge(@default_config, Map.new(opts))

    state = %{
      world_id: nil,
      config: config,
      agents: %{},
      food: %{},  # Map of hex => %{energy: float}
      walls: MapSet.new(),
      tick: 0,
      generation: 0,
      mode: :realtime,
      running: false,
      next_agent_id: 1,
      stats: %{births: 0, deaths: 0, food_eaten: 0, attacks: 0, kills: 0,
               encounters: 0, peaceful_encounters: 0, diplomatic_successes: 0},
      prev_best_fitness: 0.0,
      silo_update_tick: 0,
      species_info: %{},
      species_update_tick: 0
    }

    send(self(), :init_world)
    {:ok, state}
  end

  @impl true
  def handle_info(:init_world, state) do
    {:ok, world} = Worlds.get_or_create_default_world()

    # Generate maze using scatter approach for controlled wall density
    walls = HexMaze.generate_scatter(state.config.arena_radius,
      wall_percent: state.config.wall_percent,
      open_center_radius: state.config.open_center_radius
    )

    state = %{state |
      world_id: world.id,
      walls: walls
    }

    # Spawn initial population and food
    state = spawn_initial_population(state)
    state = spawn_initial_food(state)

    maze_stats = HexMaze.stats(walls, state.config.arena_radius)
    Logger.info("[HexWorldServer] Initialized with #{map_size(state.agents)} agents, " <>
                "#{maze_stats.wall_percent}% walls")

    # Broadcast walls once on init
    broadcast_walls(state)

    # Auto-start simulation
    state = %{state | running: true}
    schedule_tick(state)

    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, %{running: false} = state), do: {:noreply, state}

  @impl true
  def handle_info(:tick, state) do
    Logger.debug("[HexWorldServer] Tick #{state.tick} - #{map_size(state.agents)} agents")
    state = simulation_step(state)
    schedule_tick(state)
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
    # Generate new maze using scatter approach
    walls = HexMaze.generate_scatter(state.config.arena_radius,
      wall_percent: state.config.wall_percent,
      open_center_radius: state.config.open_center_radius
    )

    state = %{state |
      agents: %{},
      food: %{},
      walls: walls,
      tick: 0,
      generation: 0,
      next_agent_id: 1,
      stats: %{births: 0, deaths: 0, food_eaten: 0, attacks: 0, kills: 0,
               encounters: 0, peaceful_encounters: 0, diplomatic_successes: 0},
      prev_best_fitness: 0.0,
      silo_update_tick: 0,
      species_info: %{},
      species_update_tick: 0
    }

    state = spawn_initial_population(state)
    state = spawn_initial_food(state)

    broadcast_walls(state)
    broadcast_state(state)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    render_state = %{
      agents: state.agents |> Map.values() |> Enum.map(&agent_to_render(&1, state)),
      food: state.food |> Enum.map(&food_to_render(&1, state)),
      walls: state.walls |> MapSet.to_list() |> Enum.map(&Tuple.to_list/1),
      tick: state.tick,
      generation: state.generation,
      running: state.running,
      mode: state.mode,
      config: %{
        arena_radius: state.config.arena_radius,
        hex_size: state.config.hex_size
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
      food_count: map_size(state.food),
      best_fitness: Enum.max(fitness_values, fn -> 0 end),
      avg_fitness: safe_avg(fitness_values),
      total_births: state.stats.births,
      total_deaths: state.stats.deaths,
      total_food_eaten: state.stats.food_eaten,
      total_attacks: state.stats.attacks,
      total_kills: state.stats.kills,
      total_encounters: state.stats.encounters,
      total_peaceful_encounters: state.stats.peaceful_encounters,
      total_diplomatic_successes: state.stats.diplomatic_successes,
      cooperation_rate: calculate_rate(state.stats.peaceful_encounters, state.stats.encounters),
      diplomacy_rate: calculate_rate(state.stats.diplomatic_successes, state.stats.peaceful_encounters)
    }

    {:reply, stats, state}
  end

  # Simulation Logic
  defp simulation_step(state) do
    state
    |> increment_tick()
    |> update_agents()
    |> handle_encounters()
    |> handle_attacks()
    |> handle_eating()
    |> handle_reproduction()
    |> handle_deaths()
    |> maintain_population()
    |> spawn_food()
    |> maybe_update_silo()
    |> maybe_update_species()
  end

  defp increment_tick(state), do: %{state | tick: state.tick + 1}

  defp update_agents(state) do
    %{walls: walls, config: config} = state
    arena_radius = config.arena_radius

    # Build map of occupied hexes for collision detection
    occupied = state.agents |> Map.values() |> Enum.map(& &1.hex) |> MapSet.new()

    updated_agents =
      state.agents
      |> Enum.map(fn {id, agent} ->
        other_agents = state.agents |> Map.delete(id)
        updated = update_single_agent(agent, other_agents, state.food, walls, arena_radius, occupied, state.tick)
        {id, updated}
      end)
      |> Map.new()

    %{state | agents: updated_agents}
  end

  defp update_single_agent(agent, other_agents, food, walls, arena_radius, occupied, tick) do
    # Cast vision rays (with wall occlusion)
    vision = HexVision.cast_rays(agent.hex, other_agents, food, walls, arena_radius)

    # Calculate hearing (signals from nearby agents)
    hearing = calculate_hearing(agent, other_agents)

    # Calculate smell (food density, prey, threats)
    smell = calculate_smell(agent, other_agents, food)

    # Build inputs and evaluate network
    inputs = AgentBrain.build_hex_inputs(agent, vision, hearing, smell)
    outputs = AgentBrain.evaluate(agent.network, inputs)
    actions = AgentBrain.parse_hex_outputs(outputs)

    # Use Actuator to get movement event
    world_context = %{walls: walls, arena_radius: arena_radius, occupied: occupied, tick: tick}
    {:ok, move_event} = Actuator.move(agent, actions.directions, world_context)

    # Emit event if movement occurred
    if move_event do
      Phoenix.PubSub.broadcast(@pubsub, @topic_agent_moved, move_event)
    end

    # Apply event to update agent state
    apply_movement_event(agent, move_event, actions)
  end

  # Apply movement event to agent state
  defp apply_movement_event(agent, nil, actions) do
    # No movement - just update non-position state
    %{agent |
      energy: agent.energy - @move_cost,
      age: agent.age + 1,
      fitness: agent.fitness + 1,
      signal: actions.signal,
      wants_attack: actions.attack
    }
  end

  defp apply_movement_event(agent, %{type: :agent_moved} = event, actions) do
    new_direction = event.direction * :math.pi() / 3  # Convert 0-5 to radians

    %{agent |
      hex: event.to_hex,
      direction: new_direction,
      last_direction: event.direction,
      energy: agent.energy - @move_cost,
      age: agent.age + 1,
      fitness: agent.fitness + 1,
      signal: actions.signal,
      wants_attack: actions.attack
    }
  end


  defp calculate_hearing(agent, other_agents) do
    other_list = Map.values(other_agents)

    nearby_signals =
      other_list
      |> Enum.map(fn other ->
        distance = Hex.distance(agent.hex, other.hex)
        {distance, Map.get(other, :signal, 0.5)}
      end)
      |> Enum.filter(fn {dist, _} -> dist <= @hearing_range end)
      |> Enum.sort_by(fn {dist, _} -> dist end)
      |> Enum.take(4)
      |> Enum.map(fn {_dist, signal} -> signal end)

    # Pad with 0.0 if fewer than 4 nearby agents
    nearby_signals ++ List.duplicate(0.0, 4 - length(nearby_signals))
  end

  defp calculate_smell(agent, other_agents, food) do
    other_list = Map.values(other_agents)

    # Count food within smell range
    food_count =
      food
      |> Map.keys()
      |> Enum.count(fn food_hex ->
        Hex.distance(agent.hex, food_hex) <= @smell_range
      end)

    # Count nearby agents by energy level
    {prey_count, threat_count} =
      other_list
      |> Enum.reduce({0, 0}, fn other, {prey, threat} ->
        distance = Hex.distance(agent.hex, other.hex)
        if distance <= @smell_range do
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

  @encounter_range 3
  @high_signal_threshold 0.7

  defp handle_encounters(state) do
    agents = state.agents
    agent_list = Map.to_list(agents)

    {encounters, peaceful, diplomatic, updated_agents} =
      agent_list
      |> Enum.with_index()
      |> Enum.reduce({0, 0, 0, agents}, fn {{id1, agent1}, idx}, {enc, peace, diplo, acc_agents} ->
        nearby = agent_list
          |> Enum.drop(idx + 1)
          |> Enum.filter(fn {_id2, agent2} ->
            Hex.distance(agent1.hex, agent2.hex) <= @encounter_range
          end)

        Enum.reduce(nearby, {enc, peace, diplo, acc_agents}, fn {id2, agent2}, {e, p, d, agents_acc} ->
          new_e = e + 1

          a1_wants_attack = Map.get(agent1, :wants_attack, false)
          a2_wants_attack = Map.get(agent2, :wants_attack, false)

          if not a1_wants_attack and not a2_wants_attack do
            new_p = p + 1

            updated1 = Map.update(agents_acc[id1], :peaceful_encounters, 1, &(&1 + 1))
            updated2 = Map.update(agents_acc[id2], :peaceful_encounters, 1, &(&1 + 1))
            agents_acc = agents_acc |> Map.put(id1, updated1) |> Map.put(id2, updated2)

            a1_signal = Map.get(agent1, :signal, 0.5)
            a2_signal = Map.get(agent2, :signal, 0.5)

            if a1_signal > @high_signal_threshold or a2_signal > @high_signal_threshold do
              new_d = d + 1
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

  @attack_range 1  # Must be adjacent to attack

  defp handle_attacks(state) do
    agents = state.agents

    attackers =
      agents
      |> Enum.filter(fn {_id, agent} -> Map.get(agent, :wants_attack, false) end)

    {updated_agents, kills, attacks} =
      Enum.reduce(attackers, {agents, 0, 0}, fn {attacker_id, _}, {acc_agents, acc_kills, acc_attacks} ->
        case Map.get(acc_agents, attacker_id) do
          nil ->
            {acc_agents, acc_kills, acc_attacks}

          current_attacker ->
            victim =
              acc_agents
              |> Enum.reject(fn {id, _} -> id == attacker_id end)
              |> Enum.map(fn {id, other} ->
                distance = Hex.distance(current_attacker.hex, other.hex)
                {id, other, distance}
              end)
              |> Enum.filter(fn {_, _, dist} -> dist <= @attack_range end)
              |> Enum.min_by(fn {_, _, dist} -> dist end, fn -> nil end)

            attacker_after_cost = %{current_attacker | energy: current_attacker.energy - @attack_cost}
            acc_agents = Map.put(acc_agents, attacker_id, attacker_after_cost)

            case victim do
              nil ->
                {acc_agents, acc_kills, acc_attacks + 1}

              {victim_id, victim_agent, _distance} ->
                energy_gained = victim_agent.energy * @attack_energy_transfer
                updated_attacker = %{attacker_after_cost |
                  energy: min(attacker_after_cost.energy + energy_gained, @max_energy),
                  fitness: attacker_after_cost.fitness + 100,
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
    # Eating is automatic when on food hex
    {agents, food, eaten_count} =
      Enum.reduce(state.agents, {%{}, state.food, 0}, fn {id, agent}, {acc_agents, acc_food, count} ->
        case Map.get(acc_food, agent.hex) do
          nil ->
            {Map.put(acc_agents, id, agent), acc_food, count}

          _food_data ->
            updated_agent = %{agent |
              energy: min(agent.energy + @eat_gain, @max_energy),
              food_eaten: agent.food_eaten + 1,
              fitness: agent.fitness + 50
            }
            {Map.put(acc_agents, id, updated_agent), Map.delete(acc_food, agent.hex), count + 1}
        end
      end)

    stats = %{state.stats | food_eaten: state.stats.food_eaten + eaten_count}
    %{state | agents: agents, food: food, stats: stats}
  end

  defp handle_reproduction(state) do
    {agents, new_agents, births} =
      Enum.reduce(state.agents, {%{}, [], 0}, fn {id, agent}, {acc, new_acc, births} ->
        if agent.energy > @reproduction_threshold do
          parent = %{agent | energy: agent.energy - @reproduction_cost}
          offspring = create_offspring(parent, state)
          {Map.put(acc, id, parent), [offspring | new_acc], births + 1}
        else
          {Map.put(acc, id, agent), new_acc, births}
        end
      end)

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
    %{config: config, walls: walls} = state

    offspring_network = AgentBrain.create_hex_offspring(
      parent.network,
      config.mutation_rate,
      config.mutation_strength
    )

    # Spawn on adjacent open hex, or same hex if blocked
    spawn_hex =
      parent.hex
      |> Hex.passable_neighbors(walls, config.arena_radius)
      |> Enum.shuffle()
      |> List.first(parent.hex)

    %{
      id: nil,
      hex: spawn_hex,
      direction: :rand.uniform() * 2 * :math.pi(),
      last_direction: nil,
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
      wants_attack: false,
      signal: parent.signal
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

  # Maintain minimum population by spawning agents with evolved networks
  @min_population_ratio 0.3  # Respawn when below 30% of starting population

  defp maintain_population(state) do
    %{config: config, agents: agents} = state
    current_pop = map_size(agents)
    min_pop = round(config.starting_population * @min_population_ratio)

    if current_pop < min_pop do
      # Spawn evolved agents to maintain population
      to_spawn = min_pop - current_pop
      spawn_evolved_agents(state, to_spawn)
    else
      state
    end
  end

  defp spawn_evolved_agents(state, count) when count <= 0, do: state

  defp spawn_evolved_agents(state, count) do
    %{config: config, walls: walls, agents: agents, next_agent_id: next_id, generation: gen} = state

    {new_agents, final_id} =
      Enum.reduce(1..count, {agents, next_id}, fn _, {acc, id} ->
        hex = Hex.random_open_hex(config.arena_radius, walls) || {0, 0}
        network = get_evolved_network_or_random()

        agent = %{
          id: id,
          hex: hex,
          direction: :rand.uniform() * 2 * :math.pi(),
          last_direction: nil,
          energy: 100.0,
          age: 0,
          generation: gen,
          fitness: 0.0,
          food_eaten: 0,
          kills: 0,
          peaceful_encounters: 0,
          diplomatic_successes: 0,
          network: network,
          parent_id: nil,
          species_id: "evolved",
          wants_attack: false,
          signal: 0.5
        }

        {Map.put(acc, id, agent), id + 1}
      end)

    %{state | agents: new_agents, next_agent_id: final_id}
  end

  defp spawn_food(state) do
    %{config: config, food: food, walls: walls} = state

    new_food =
      if map_size(food) < config.max_food and :rand.uniform() < config.food_spawn_rate do
        case Hex.random_open_hex(config.arena_radius, walls) do
          nil -> food
          hex ->
            if Map.has_key?(food, hex) do
              food  # Already has food
            else
              Map.put(food, hex, %{energy: @food_energy})
            end
        end
      else
        food
      end

    %{state | food: new_food}
  end

  # Silo and species updates
  @silo_update_interval 100

  defp maybe_update_silo(state) do
    if state.tick - state.silo_update_tick >= @silo_update_interval do
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

    stats = %{
      best_fitness: best_fitness,
      avg_fitness: avg_fitness,
      improvement: improvement,
      total_evaluations: state.tick,
      generation: state.generation,
      population_size: length(agent_list)
    }

    recommendations = SiloIntegration.get_recommendations(stats)

    mutation_rate = Map.get(recommendations, :mutation_rate, state.config.mutation_rate)
    mutation_strength = Map.get(recommendations, :mutation_strength, state.config.mutation_strength)

    emit_domain_signals(state, best_fitness)

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

  defp emit_domain_signals(state, best_fitness) do
    world_state = %{
      agents: state.agents,
      food: state.food,
      config: state.config,
      stats: state.stats
    }

    metrics = %{
      prev_best_fitness: state.prev_best_fitness,
      best_fitness: best_fitness
    }

    signals = DomainBridge.emit_signals(world_state, metrics)

    try do
      :signal_router.route(signals)
    rescue
      _error -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  @species_update_interval 200

  defp maybe_update_species(state) do
    if state.tick - state.species_update_tick >= @species_update_interval and map_size(state.agents) > 0 do
      update_species(state)
    else
      state
    end
  end

  defp update_species(state) do
    {updated_agents, species_info} = SpeciesTracker.assign_species(state.agents, 0.4)
    %{state |
      agents: updated_agents,
      species_info: species_info,
      species_update_tick: state.tick
    }
  end

  # Initialization
  defp spawn_initial_population(state) do
    %{config: config, walls: walls} = state

    agents =
      1..config.starting_population
      |> Enum.map(fn id ->
        # Spawn on random open hex near center
        hex = Hex.random_open_hex(config.open_center_radius, walls) ||
              Hex.random_open_hex(config.arena_radius, walls) ||
              {0, 0}

        # Try to get evolved network from training, else create random
        network = get_evolved_network_or_random()

        agent = %{
          id: id,
          hex: hex,
          direction: :rand.uniform() * 2 * :math.pi(),
          last_direction: nil,
          energy: 100.0,
          age: 0,
          generation: 0,
          fitness: 0.0,
          food_eaten: 0,
          kills: 0,
          peaceful_encounters: 0,
          diplomatic_successes: 0,
          network: network,
          parent_id: nil,
          species_id: "gen0",
          wants_attack: false,
          signal: 0.5
        }
        {id, agent}
      end)
      |> Map.new()

    %{state |
      agents: agents,
      next_agent_id: config.starting_population + 1
    }
  end

  # Try to get an evolved network from TrainingServer, with mutation
  defp get_evolved_network_or_random do
    try do
      case TrainingServer.get_best_network() do
        nil ->
          Logger.debug("[HexWorldServer] No evolved network yet, using random")
          AgentBrain.create_hex_network()

        network ->
          Logger.debug("[HexWorldServer] Using evolved network from training")
          # Mutate the evolved network for diversity
          AgentBrain.mutate(network, 0.15, 0.3)
      end
    catch
      :exit, _ ->
        Logger.debug("[HexWorldServer] TrainingServer not ready, using random")
        AgentBrain.create_hex_network()
    end
  end

  defp spawn_initial_food(state) do
    %{config: config, walls: walls} = state

    food =
      1..config.max_food
      |> Enum.reduce(%{}, fn _, acc ->
        case Hex.random_open_hex(config.arena_radius, walls) do
          nil -> acc
          hex ->
            if Map.has_key?(acc, hex) do
              acc
            else
              Map.put(acc, hex, %{energy: @food_energy})
            end
        end
      end)

    %{state | food: food}
  end

  # Helpers
  defp schedule_tick(state) do
    interval = case state.mode do
      :realtime -> state.config.tick_interval_realtime
      :fast -> state.config.tick_interval_fast
    end
    Process.send_after(self(), :tick, interval)
  end

  defp broadcast_walls(state) do
    walls_list = state.walls |> MapSet.to_list() |> Enum.map(&Tuple.to_list/1)
    msg = %{
      type: :arena_init,
      walls: walls_list,
      config: %{
        arena_radius: state.config.arena_radius,
        hex_size: state.config.hex_size
      }
    }
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:arena_init, msg})
  end

  defp broadcast_state(state) do
    should_broadcast = case state.mode do
      :realtime -> rem(state.tick, 5) == 0
      :fast -> rem(state.tick, 50) == 0
    end

    if should_broadcast do
      agents_list = Map.values(state.agents)
      {best_fit, avg_fit} = calculate_fitness_stats(agents_list)

      species_stats = SpeciesTracker.get_species_stats(state.species_info)
      diversity = SpeciesTracker.diversity_index(state.species_info)
      behavioral_types = calculate_behavioral_types(agents_list)

      render_state = %{
        agents: Enum.map(agents_list, &agent_to_render(&1, state)),
        food: state.food |> Enum.map(&food_to_render(&1, state)),
        tick: state.tick,
        population: map_size(state.agents),
        running: state.running,
        mode: state.mode,
        generation: state.generation,
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
        species: species_stats,
        diversity: diversity,
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
    {x, y} = Hex.to_pixel(agent.hex, state.config.hex_size)

    %{
      id: agent.id,
      hex: Tuple.to_list(agent.hex),
      x: x,
      y: y,
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

  defp food_to_render({hex, %{energy: energy}}, state) do
    {x, y} = Hex.to_pixel(hex, state.config.hex_size)

    %{
      hex: Tuple.to_list(hex),
      x: x,
      y: y,
      energy: energy
    }
  end

  defp safe_avg([]), do: 0.0
  defp safe_avg(list), do: Enum.sum(list) / length(list)

  defp calculate_rate(_numerator, 0), do: 0.0
  defp calculate_rate(numerator, denominator), do: numerator / denominator
end
