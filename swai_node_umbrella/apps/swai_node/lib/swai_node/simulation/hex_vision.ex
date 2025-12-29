defmodule SwaiNode.Simulation.HexVision do
  @moduledoc """
  Hex-based raycasting with wall occlusion.

  Casts 6 rays (one per direction) and detects:
  - Food distance (normalized 0-1, 1 = at max range)
  - Agent distance (normalized 0-1)
  - Wall distance (normalized 0-1)

  Walls block line of sight - rays stop when hitting a wall.

  ## Output Format

  Returns a flat list of 18 floats:
  - Indices 0-5: Food distances in each direction
  - Indices 6-11: Agent distances in each direction
  - Indices 12-17: Wall distances in each direction

  All distances normalized to 0-1 where:
  - 0 = nothing detected in range
  - 1 = detected at distance 1 (immediate neighbor)
  - Values decrease with distance
  """

  alias SwaiNode.Simulation.Hex

  @max_ray_distance 10
  @direction_count 6

  @doc """
  Casts vision rays from an agent's position.

  Returns a list of 18 floats representing what the agent sees
  in each of the 6 directions.

  ## Parameters

  - `agent_hex` - Agent's current hex position
  - `other_agents` - Map of agent_id => agent, or list of agents
  - `food` - Map of hex => food_data
  - `walls` - MapSet of wall hexes
  - `arena_radius` - Arena boundary radius

  ## Returns

  List of 18 floats: [food_0..food_5, agent_0..agent_5, wall_0..wall_5]
  """
  @spec cast_rays(
          {integer(), integer()},
          map() | list(),
          map(),
          MapSet.t(),
          pos_integer()
        ) :: list(float())
  def cast_rays(agent_hex, other_agents, food, walls, arena_radius) do
    # Convert agents to list of hexes if needed
    agent_hexes =
      case other_agents do
        agents when is_map(agents) ->
          agents |> Map.values() |> Enum.map(& &1.hex) |> MapSet.new()

        agents when is_list(agents) ->
          agents |> Enum.map(& &1.hex) |> MapSet.new()
      end

    # Food is a map of hex => data
    food_hexes = food |> Map.keys() |> MapSet.new()

    # Cast ray in each direction
    results =
      for dir <- 0..(@direction_count - 1) do
        cast_ray(agent_hex, dir, agent_hexes, food_hexes, walls, arena_radius)
      end

    # Flatten into [food_0..food_5, agent_0..agent_5, wall_0..wall_5]
    food_dists = Enum.map(results, fn {food, _, _} -> food end)
    agent_dists = Enum.map(results, fn {_, agent, _} -> agent end)
    wall_dists = Enum.map(results, fn {_, _, wall} -> wall end)

    food_dists ++ agent_dists ++ wall_dists
  end

  @doc """
  Casts a single ray in the given direction.

  Returns {food_dist, agent_dist, wall_dist} where each is normalized 0-1.
  - 0 = nothing detected
  - Higher values = closer detection
  """
  @spec cast_ray(
          {integer(), integer()},
          non_neg_integer(),
          MapSet.t(),
          MapSet.t(),
          MapSet.t(),
          pos_integer()
        ) :: {float(), float(), float()}
  def cast_ray(from_hex, direction, agent_hexes, food_hexes, walls, arena_radius) do
    do_cast_ray(from_hex, direction, agent_hexes, food_hexes, walls, arena_radius, 1, {0.0, 0.0, 0.0})
  end

  defp do_cast_ray(current, direction, agent_hexes, food_hexes, walls, arena_radius, distance, {food_dist, agent_dist, wall_dist}) do
    # Stop at max range
    if distance > @max_ray_distance do
      {food_dist, agent_dist, wall_dist}
    else
      # Move one step in direction
      next_hex = Hex.neighbor(current, direction)

      cond do
        # Hit arena boundary - treat as wall
        not Hex.in_bounds?(next_hex, arena_radius) ->
          new_wall_dist = if wall_dist == 0.0, do: normalize_distance(distance), else: wall_dist
          {food_dist, agent_dist, new_wall_dist}

        # Hit wall - stops the ray
        MapSet.member?(walls, next_hex) ->
          new_wall_dist = if wall_dist == 0.0, do: normalize_distance(distance), else: wall_dist
          {food_dist, agent_dist, new_wall_dist}

        true ->
          # Check for food
          new_food_dist =
            if food_dist == 0.0 and MapSet.member?(food_hexes, next_hex) do
              normalize_distance(distance)
            else
              food_dist
            end

          # Check for agent
          new_agent_dist =
            if agent_dist == 0.0 and MapSet.member?(agent_hexes, next_hex) do
              normalize_distance(distance)
            else
              agent_dist
            end

          # Continue ray
          do_cast_ray(next_hex, direction, agent_hexes, food_hexes, walls, arena_radius, distance + 1, {new_food_dist, new_agent_dist, wall_dist})
      end
    end
  end

  # Normalize distance to 0-1 where closer = higher value
  # Using inverse: 1/distance, clamped to max 1.0
  defp normalize_distance(distance) when distance > 0 do
    1.0 / distance
  end

  @doc """
  Returns the number of vision inputs (18).
  """
  @spec input_count() :: pos_integer()
  def input_count, do: @direction_count * 3

  @doc """
  Returns the max ray distance.
  """
  @spec max_ray_distance() :: pos_integer()
  def max_ray_distance, do: @max_ray_distance

  @doc """
  Checks if there is line of sight between two hexes.

  Returns true if no walls block the path.
  """
  @spec has_line_of_sight?(
          {integer(), integer()},
          {integer(), integer()},
          MapSet.t()
        ) :: boolean()
  def has_line_of_sight?(from_hex, to_hex, walls) do
    path = Hex.line(from_hex, to_hex)

    # Check all hexes in path except start and end
    path
    |> Enum.drop(1)
    |> Enum.take(length(path) - 2)
    |> Enum.all?(fn hex -> not MapSet.member?(walls, hex) end)
  end

  @doc """
  Returns what the agent can see (for debugging/visualization).

  Returns a map of direction => list of visible hexes.
  """
  @spec visible_hexes(
          {integer(), integer()},
          MapSet.t(),
          pos_integer()
        ) :: map()
  def visible_hexes(agent_hex, walls, arena_radius) do
    for dir <- 0..(@direction_count - 1), into: %{} do
      hexes = get_visible_in_direction(agent_hex, dir, walls, arena_radius, [])
      {dir, hexes}
    end
  end

  defp get_visible_in_direction(current, direction, walls, arena_radius, acc) do
    if length(acc) >= @max_ray_distance do
      Enum.reverse(acc)
    else
      next_hex = Hex.neighbor(current, direction)

      cond do
        not Hex.in_bounds?(next_hex, arena_radius) ->
          Enum.reverse(acc)

        MapSet.member?(walls, next_hex) ->
          Enum.reverse([next_hex | acc])

        true ->
          get_visible_in_direction(next_hex, direction, walls, arena_radius, [next_hex | acc])
      end
    end
  end
end
