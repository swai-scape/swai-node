defmodule SwaiNode.DomainSDK.HexArenaEnvironment do
  @moduledoc """
  Hex-based arena environment for agent evaluation.

  Implements the `agent_environment` behaviour from the Domain SDK.

  ## Episode Flow

  1. `init/1` - Generate walls, spawn initial food
  2. `spawn_agent/2` - Place agent at center with starting energy
  3. `tick/2` → `apply_action/3` - Repeat until terminal
  4. `is_terminal/2` - Check energy <= 0 or max ticks reached
  5. `extract_metrics/2` - Gather fitness metrics

  ## Configuration

  | Parameter        | Default | Description                    |
  |------------------|---------|--------------------------------|
  | arena_radius     | 40      | Hex radius of arena            |
  | max_ticks        | 500     | Maximum episode length         |
  | wall_percent     | 10      | Percentage of walls            |
  | max_food         | 80      | Maximum food items             |
  | food_spawn_rate  | 0.8     | Food spawn probability/tick    |
  """

  # Implements :agent_environment behaviour (Erlang)

  alias SwaiNode.Simulation.{Hex, HexMaze}

  # Default parameters
  @default_arena_radius 40
  @default_max_ticks 500
  @default_wall_percent 10
  @default_open_center 5
  @default_max_food 80
  @default_food_spawn_rate 0.8
  @default_starting_energy 150.0
  @default_max_energy 300.0
  @default_move_cost 0.3
  @default_eat_gain 40.0

  def name, do: <<"hex_arena">>

  def init(config) do
    arena_radius = Map.get(config, :arena_radius, @default_arena_radius)
    max_ticks = Map.get(config, :max_ticks, @default_max_ticks)
    wall_percent = Map.get(config, :wall_percent, @default_wall_percent)
    open_center = Map.get(config, :open_center_radius, @default_open_center)
    max_food = Map.get(config, :max_food, @default_max_food)
    food_spawn_rate = Map.get(config, :food_spawn_rate, @default_food_spawn_rate)

    walls = HexMaze.generate_scatter(arena_radius,
      wall_percent: wall_percent,
      open_center_radius: open_center
    )

    food = spawn_initial_food(walls, arena_radius, 10)

    env_state = %{
      arena_radius: arena_radius,
      max_ticks: max_ticks,
      max_food: max_food,
      food_spawn_rate: food_spawn_rate,
      walls: walls,
      food: food,
      agents: %{},
      tick: 0,
      starting_energy: Map.get(config, :starting_energy, @default_starting_energy),
      max_energy: Map.get(config, :max_energy, @default_max_energy),
      move_cost: Map.get(config, :move_cost, @default_move_cost),
      eat_gain: Map.get(config, :eat_gain, @default_eat_gain)
    }

    {:ok, env_state}
  end

  def spawn_agent(agent_id, env_state) do
    starting_energy = Map.get(env_state, :starting_energy, @default_starting_energy)

    agent_state = %{
      id: agent_id,
      hex: {0, 0},
      energy: starting_energy,
      age: 0,
      signal: 0.5,
      generation: 0,
      food_eaten: 0,
      kills: 0,
      last_direction: nil
    }

    updated_env = put_in(env_state, [:agents, agent_id], agent_state)
    {:ok, agent_state, updated_env}
  end

  def tick(agent_state, env_state) do
    new_tick = Map.get(env_state, :tick, 0) + 1
    env_state = Map.put(env_state, :tick, new_tick)
    env_state = maybe_spawn_food(env_state)
    {:ok, agent_state, env_state}
  end

  def apply_action(action, agent_state, env_state) do
    # Handle composite actions from multiple actuators
    agent_state = apply_movement(action, agent_state, env_state)
    agent_state = apply_signal(action, agent_state)
    {agent_state, env_state} = apply_eating(agent_state, env_state)

    # Update agent in environment
    agent_id = Map.get(agent_state, :id)
    env_state = put_in(env_state, [:agents, agent_id], agent_state)

    {:ok, agent_state, env_state}
  end

  def is_terminal(agent_state, env_state) do
    energy = Map.get(agent_state, :energy, 0)
    tick = Map.get(env_state, :tick, 0)
    max_ticks = Map.get(env_state, :max_ticks, @default_max_ticks)
    energy <= 0 or tick >= max_ticks
  end

  def extract_metrics(agent_state, env_state) do
    %{
      ticks_survived: Map.get(agent_state, :age, 0),
      food_eaten: Map.get(agent_state, :food_eaten, 0),
      kills: Map.get(agent_state, :kills, 0),
      final_energy: Map.get(agent_state, :energy, 0),
      final_tick: Map.get(env_state, :tick, 0)
    }
  end

  # Private helpers

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

  defp apply_movement(action, agent_state, env_state) do
    direction_idx = Map.get(action, :direction_index, 6)
    walls = Map.get(env_state, :walls, MapSet.new())
    arena_radius = Map.get(env_state, :arena_radius, @default_arena_radius)
    move_cost = Map.get(env_state, :move_cost, @default_move_cost)
    current_hex = Map.get(agent_state, :hex, {0, 0})

    new_hex = compute_new_hex(current_hex, direction_idx, walls, arena_radius)

    %{agent_state |
      hex: new_hex,
      energy: Map.get(agent_state, :energy, 0) - move_cost,
      age: Map.get(agent_state, :age, 0) + 1,
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
    %{agent_state | signal: signal}
  end

  defp apply_eating(agent_state, env_state) do
    hex = Map.get(agent_state, :hex)
    food = Map.get(env_state, :food, %{})
    eat_gain = Map.get(env_state, :eat_gain, @default_eat_gain)
    max_energy = Map.get(env_state, :max_energy, @default_max_energy)

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
  end
end
