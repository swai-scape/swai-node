defmodule SwaiNode.Simulation.Vision do
  @moduledoc """
  Ray-casting vision system for agents.

  Casts 8 rays in different directions with SEPARATE channels for:
  - Food (green channel)
  - Agents (red channel)
  - Walls (blue channel)

  This allows agents to distinguish between object types, enabling
  evolution of food-seeking vs threat-avoidance behaviors.

  Returns 24 floats: 8 rays × 3 channels (food, agent, wall).
  Each value is normalized (0 = touching, 1 = max vision range or not seen).
  """

  @ray_count 8
  @max_vision_range 100.0
  @agent_radius 5.0
  @food_radius 3.0

  # Angles for 8 rays (in radians, starting from agent's facing direction)
  @ray_offsets [0, :math.pi() / 4, :math.pi() / 2, 3 * :math.pi() / 4,
                :math.pi(), -3 * :math.pi() / 4, -:math.pi() / 2, -:math.pi() / 4]

  @doc """
  Cast vision rays from an agent and return what they see.

  Returns a list of 24 floats organized as:
  - 8 food distances (rays 0-7)
  - 8 agent distances (rays 0-7)
  - 8 wall distances (rays 0-7)

  Each value is 0-1 (0 = touching, 1 = max range or not detected).
  """
  @spec cast_rays(map(), list(map()), list(tuple()), {integer(), integer()}) :: list(float())
  def cast_rays(agent, other_agents, food_positions, {world_width, world_height}) do
    %{x: ax, y: ay, direction: direction} = agent

    # Cast all rays and collect per-channel results
    ray_results = Enum.map(@ray_offsets, fn offset ->
      ray_angle = direction + offset
      cast_single_ray_multichannel(ax, ay, ray_angle, other_agents, food_positions, world_width, world_height)
    end)

    # Reorganize: all food, then all agents, then all walls
    food_distances = Enum.map(ray_results, fn {food, _agent, _wall} -> food end)
    agent_distances = Enum.map(ray_results, fn {_food, agent, _wall} -> agent end)
    wall_distances = Enum.map(ray_results, fn {_food, _agent, wall} -> wall end)

    food_distances ++ agent_distances ++ wall_distances
  end

  @doc """
  Cast a single ray and return distances to each object type.

  Returns {food_dist, agent_dist, wall_dist} as normalized values.
  """
  def cast_single_ray_multichannel(start_x, start_y, angle, other_agents, food_positions, world_width, world_height) do
    # Calculate ray direction vector
    dx = :math.cos(angle)
    dy = :math.sin(angle)

    # Find distance to each object type separately
    wall_dist = distance_to_wall(start_x, start_y, dx, dy, world_width, world_height)
    food_dist = distance_to_nearest_food(start_x, start_y, dx, dy, food_positions)
    agent_dist = distance_to_nearest_agent(start_x, start_y, dx, dy, other_agents)

    {normalize_distance(food_dist), normalize_distance(agent_dist), normalize_distance(wall_dist)}
  end

  @doc """
  Cast a single ray and return normalized distance to nearest object (legacy).
  Kept for backwards compatibility.
  """
  def cast_single_ray(start_x, start_y, angle, other_agents, food_positions, world_width, world_height) do
    {food_dist, agent_dist, wall_dist} =
      cast_single_ray_multichannel(start_x, start_y, angle, other_agents, food_positions, world_width, world_height)

    # Return nearest of all three
    Enum.min([food_dist, agent_dist, wall_dist])
  end

  # Calculate distance to wall along ray
  defp distance_to_wall(x, y, dx, dy, width, height) do
    # Calculate intersection with each wall
    distances = []

    # Right wall (x = width)
    distances = if dx > 0, do: [(width - x) / dx | distances], else: distances
    # Left wall (x = 0)
    distances = if dx < 0, do: [-x / dx | distances], else: distances
    # Bottom wall (y = height)
    distances = if dy > 0, do: [(height - y) / dy | distances], else: distances
    # Top wall (y = 0)
    distances = if dy < 0, do: [-y / dy | distances], else: distances

    case Enum.filter(distances, &(&1 > 0)) do
      [] -> @max_vision_range
      positive -> Enum.min(positive)
    end
  end

  # Calculate distance to nearest food along ray
  defp distance_to_nearest_food(x, y, dx, dy, food_positions) do
    food_positions
    |> Enum.map(fn {fx, fy, _energy} ->
      distance_to_circle(x, y, dx, dy, fx, fy, @food_radius)
    end)
    |> Enum.filter(&(&1 != nil))
    |> case do
      [] -> @max_vision_range
      distances -> Enum.min(distances)
    end
  end

  # Calculate distance to nearest agent along ray
  defp distance_to_nearest_agent(x, y, dx, dy, other_agents) do
    other_agents
    |> Enum.map(fn %{x: ax, y: ay} ->
      distance_to_circle(x, y, dx, dy, ax, ay, @agent_radius)
    end)
    |> Enum.filter(&(&1 != nil))
    |> case do
      [] -> @max_vision_range
      distances -> Enum.min(distances)
    end
  end

  # Calculate distance from ray to circle (returns nil if no intersection)
  defp distance_to_circle(ray_x, ray_y, ray_dx, ray_dy, circle_x, circle_y, radius) do
    # Vector from ray origin to circle center
    fx = ray_x - circle_x
    fy = ray_y - circle_y

    # Quadratic formula coefficients
    a = ray_dx * ray_dx + ray_dy * ray_dy
    b = 2 * (fx * ray_dx + fy * ray_dy)
    c = fx * fx + fy * fy - radius * radius

    discriminant = b * b - 4 * a * c

    cond do
      discriminant < 0 ->
        nil

      true ->
        sqrt_disc = :math.sqrt(discriminant)
        t1 = (-b - sqrt_disc) / (2 * a)
        t2 = (-b + sqrt_disc) / (2 * a)

        # Return nearest positive intersection
        cond do
          t1 > 0 -> t1
          t2 > 0 -> t2
          true -> nil
        end
    end
  end

  # Normalize distance to 0-1 range
  defp normalize_distance(distance) when distance >= @max_vision_range, do: 1.0
  defp normalize_distance(distance) when distance <= 0, do: 0.0
  defp normalize_distance(distance), do: distance / @max_vision_range

  @doc """
  Get the angle for a specific ray index.
  """
  @spec ray_angle(integer()) :: float()
  def ray_angle(index) when index >= 0 and index < @ray_count do
    Enum.at(@ray_offsets, index)
  end

  @doc """
  Get the maximum vision range.
  """
  @spec max_range() :: float()
  def max_range, do: @max_vision_range

  @doc """
  Get the number of vision rays.
  """
  @spec ray_count() :: integer()
  def ray_count, do: @ray_count
end
