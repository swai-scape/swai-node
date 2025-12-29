defmodule SwaiNode.Simulation.WorldSimulator do
  @moduledoc """
  Pure 2D world simulation without GenServer or evolution logic.

  Used by WorldEvaluator to evaluate individual neural networks.
  Each evaluation runs a single agent in a world full of food
  for a fixed number of ticks.

  ## Simulation Features

  - 2D physics with movement and collision
  - Vision raycasting (8 rays × 3 channels: food, agent, wall = 24 inputs)
  - Hearing (signals from 4 nearest agents)
  - Smell (food density, prey/threat density)
  - Food spawning and consumption
  - Predator-prey mechanics (attacks)
  """

  alias SwaiNode.Simulation.{AgentBrain, Vision}
  alias SwaiNode.Geo.RoadNetwork

  # Simulation constants
  # TODO: Wire to ecological_silo for dynamic tuning
  @move_cost 0.05  # Lower cost = more time to learn
  @eat_range 18.0
  @eat_gain 40.0
  @max_energy 200.0
  @agent_radius 5.0
  @food_energy 20.0

  # Predator-prey constants
  @attack_range 15.0
  @attack_cost 2.0
  @attack_energy_transfer 0.6
  @smell_range 60.0
  @max_smell_count 10.0
  @prey_energy_threshold 100.0
  @hearing_range 80.0

  # Default world configuration
  @default_options %{
    width: 800,
    height: 600,
    max_food: 150,
    food_spawn_rate: 0.8,
    # For multi-agent visualization mode
    other_agents: []
  }

  @doc """
  Run a single network evaluation in the 2D world.

  Returns a result map with metrics:
  - :ticks - How long the agent survived
  - :food_eaten - Number of food items consumed
  - :kills - Number of other agents killed (multi-agent mode)
  - :energy - Final energy level

  ## Options

  - :width - World width (default: 800)
  - :height - World height (default: 600)
  - :max_food - Maximum food items (default: 150)
  - :food_spawn_rate - Food spawn probability per tick (default: 0.8)
  - :other_agents - List of other agent networks for multi-agent mode
  """
  @spec run_evaluation(term(), pos_integer(), map()) :: map()
  def run_evaluation(network, max_ticks, options \\ %{}) do
    opts = Map.merge(@default_options, options)

    # Initialize world state
    state = init_world(network, opts)

    # Run simulation loop
    run_loop(state, 0, max_ticks)
  end

  # Initialize world with single agent and food
  defp init_world(network, opts) do
    %{
      agent: init_agent(network, opts),
      food: init_food(opts),
      config: opts,
      # Metrics
      food_eaten: 0,
      kills: 0
    }
  end

  defp init_agent(network, opts) do
    %{
      x: :rand.uniform() * opts.width,
      y: :rand.uniform() * opts.height,
      direction: :rand.uniform() * 2 * :math.pi(),
      energy: 100.0,
      network: network,
      signal: 0.5,
      wants_attack: false,
      kills: 0,
      food_eaten: 0
    }
  end

  defp init_food(opts) do
    1..opts.max_food
    |> Enum.map(fn _ ->
      x = :rand.uniform() * opts.width
      y = :rand.uniform() * opts.height
      {x, y, @food_energy}
    end)
  end

  # Main simulation loop
  defp run_loop(state, tick, max_ticks) when tick >= max_ticks do
    extract_results(state, tick)
  end

  defp run_loop(%{agent: nil} = state, tick, _max_ticks) do
    # Agent died
    extract_results(state, tick)
  end

  defp run_loop(state, tick, max_ticks) do
    state
    |> update_agent()
    |> handle_eating()
    |> handle_energy_death()
    |> spawn_food()
    |> run_loop(tick + 1, max_ticks)
  end

  # Extract final metrics
  defp extract_results(state, tick) do
    agent = state.agent || %{energy: 0}
    %{
      ticks: tick,
      food_eaten: state.food_eaten,
      kills: state.kills,
      energy: agent.energy
    }
  end

  # Update agent: vision -> brain -> movement
  defp update_agent(%{agent: nil} = state), do: state

  defp update_agent(state) do
    %{agent: agent, food: food, config: config} = state
    world_size = {config.width, config.height}
    other_agents = config.other_agents || []

    # Cast vision rays
    vision = Vision.cast_rays(agent, other_agents, food, world_size)

    # Calculate hearing (signals from nearby agents)
    hearing = calculate_hearing(agent, other_agents)

    # Calculate smell (food density, prey/threat)
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

    updated_agent = %{agent |
      x: new_x,
      y: new_y,
      direction: new_direction,
      energy: new_energy,
      signal: actions.signal,
      wants_attack: actions.attack
    }

    %{state | agent: updated_agent}
  end

  # Hearing: signals from nearest agents
  defp calculate_hearing(agent, other_agents) do
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

  # Smell: food density, prey, threats
  defp calculate_smell(agent, other_agents, food) do
    # Count food within smell range
    food_count =
      food
      |> Enum.count(fn {fx, fy, _} ->
        distance = :math.sqrt(:math.pow(agent.x - fx, 2) + :math.pow(agent.y - fy, 2))
        distance < @smell_range
      end)

    # Count nearby agents by energy level
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

  # Handle eating (automatic when near food)
  defp handle_eating(%{agent: nil} = state), do: state

  defp handle_eating(state) do
    %{agent: agent, food: food} = state

    case find_nearby_food(agent, food) do
      nil ->
        state

      {_food_item, remaining_food} ->
        updated_agent = %{agent |
          energy: min(agent.energy + @eat_gain, @max_energy),
          food_eaten: agent.food_eaten + 1
        }

        %{state |
          agent: updated_agent,
          food: remaining_food,
          food_eaten: state.food_eaten + 1
        }
    end
  end

  defp find_nearby_food(agent, food) do
    Enum.find_value(food, fn {fx, fy, _} = food_item ->
      distance = :math.sqrt(:math.pow(agent.x - fx, 2) + :math.pow(agent.y - fy, 2))
      if distance < @eat_range do
        {food_item, List.delete(food, food_item)}
      end
    end)
  end

  # Check if agent died from energy depletion
  defp handle_energy_death(%{agent: nil} = state), do: state

  defp handle_energy_death(state) do
    if state.agent.energy <= 0 do
      %{state | agent: nil}
    else
      state
    end
  end

  # Spawn food if below max - only on streets if road network available
  defp spawn_food(state) do
    %{food: food, config: config} = state

    new_food =
      if length(food) < config.max_food and :rand.uniform() < config.food_spawn_rate do
        case get_food_road_position(config) do
          {x, y} -> [{x, y, @food_energy} | food]
          nil -> food
        end
      else
        food
      end

    %{state | food: new_food}
  end

  # Get a random road position for food - within 200m of origin
  defp get_food_road_position(config) do
    geo_config = Application.get_env(:swai_node, :geo, [])
    origin_lat = Keyword.get(geo_config, :latitude, 52.5347)
    origin_lon = Keyword.get(geo_config, :longitude, 17.5828)

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

  # Convert lat/lon to world coordinates (same as WorldServer)
  # No clamping - entities can be anywhere on the road network
  defp lat_lon_to_world(lat, lon, config, origin_lat, origin_lon) do
    meters_per_deg_lat = 111_320
    meters_per_deg_lon = 111_320 * :math.cos(origin_lat * :math.pi() / 180)

    offset_x = (lon - origin_lon) * meters_per_deg_lon
    offset_y = (origin_lat - lat) * meters_per_deg_lat

    x = config.width / 2 + offset_x
    y = config.height / 2 + offset_y

    {x, y}
  end

  # ==========================================================================
  # Multi-Agent Simulation (for visualization)
  # ==========================================================================

  @doc """
  Run a full population simulation for visualization.

  This is used by the dashboard to show all agents interacting.
  Unlike run_evaluation/3, this manages multiple agents with
  reproduction and death.

  Returns updated state with all agents and events.
  """
  @spec tick_population(map()) :: map()
  def tick_population(state) do
    state
    |> update_all_agents()
    |> handle_attacks()
    |> handle_all_eating()
    |> handle_all_deaths()
    |> spawn_food()
  end

  defp update_all_agents(state) do
    %{agents: agents, food: food, config: config} = state
    world_size = {config.width, config.height}

    updated_agents =
      agents
      |> Enum.map(fn {id, agent} ->
        other_agents = agents |> Map.delete(id) |> Map.values()

        # Vision, hearing, smell
        vision = Vision.cast_rays(agent, other_agents, food, world_size)
        hearing = calculate_hearing(agent, other_agents)
        smell = calculate_smell(agent, other_agents, food)

        # Brain evaluation
        inputs = AgentBrain.build_inputs(agent, vision, hearing, smell)
        outputs = AgentBrain.evaluate(agent.network, inputs)
        actions = AgentBrain.parse_outputs(outputs)

        # Movement
        {width, height} = world_size
        new_direction = agent.direction + actions.turn * 0.1
        move_speed = actions.move * 3.0

        new_x = agent.x + :math.cos(new_direction) * move_speed
        new_y = agent.y + :math.sin(new_direction) * move_speed

        new_x = max(@agent_radius, min(width - @agent_radius, new_x))
        new_y = max(@agent_radius, min(height - @agent_radius, new_y))

        updated = %{agent |
          x: new_x,
          y: new_y,
          direction: new_direction,
          energy: agent.energy - @move_cost,
          signal: actions.signal,
          wants_attack: actions.attack
        }

        {id, updated}
      end)
      |> Map.new()

    %{state | agents: updated_agents}
  end

  defp handle_attacks(state) do
    %{agents: agents} = state

    attackers =
      agents
      |> Enum.filter(fn {_id, agent} -> Map.get(agent, :wants_attack, false) end)

    {updated_agents, kills} =
      Enum.reduce(attackers, {agents, 0}, fn {attacker_id, _}, {acc, kill_count} ->
        case Map.get(acc, attacker_id) do
          nil ->
            {acc, kill_count}

          attacker ->
            # Find nearest victim
            victim =
              acc
              |> Enum.reject(fn {id, _} -> id == attacker_id end)
              |> Enum.map(fn {id, other} ->
                dist = :math.sqrt(:math.pow(attacker.x - other.x, 2) + :math.pow(attacker.y - other.y, 2))
                {id, other, dist}
              end)
              |> Enum.filter(fn {_, _, dist} -> dist < @attack_range end)
              |> Enum.min_by(fn {_, _, dist} -> dist end, fn -> nil end)

            # Deduct attack cost
            attacker_after = %{attacker | energy: attacker.energy - @attack_cost}
            acc = Map.put(acc, attacker_id, attacker_after)

            case victim do
              nil ->
                {acc, kill_count}

              {victim_id, victim_agent, _} ->
                energy_gained = victim_agent.energy * @attack_energy_transfer
                updated_attacker = %{attacker_after |
                  energy: min(attacker_after.energy + energy_gained, @max_energy),
                  kills: Map.get(attacker_after, :kills, 0) + 1
                }

                acc = acc
                      |> Map.put(attacker_id, updated_attacker)
                      |> Map.delete(victim_id)

                {acc, kill_count + 1}
            end
        end
      end)

    %{state | agents: updated_agents, kills: state.kills + kills}
  end

  defp handle_all_eating(state) do
    %{agents: agents, food: food} = state

    {updated_agents, remaining_food, eaten} =
      Enum.reduce(agents, {%{}, food, 0}, fn {id, agent}, {acc_agents, acc_food, count} ->
        case find_nearby_food(agent, acc_food) do
          nil ->
            {Map.put(acc_agents, id, agent), acc_food, count}

          {_, new_food} ->
            updated = %{agent |
              energy: min(agent.energy + @eat_gain, @max_energy),
              food_eaten: Map.get(agent, :food_eaten, 0) + 1
            }
            {Map.put(acc_agents, id, updated), new_food, count + 1}
        end
      end)

    %{state | agents: updated_agents, food: remaining_food, food_eaten: state.food_eaten + eaten}
  end

  defp handle_all_deaths(state) do
    alive =
      state.agents
      |> Enum.filter(fn {_, agent} -> agent.energy > 0 end)
      |> Map.new()

    %{state | agents: alive}
  end
end
