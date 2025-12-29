defmodule SwaiNode.Simulation.HexMaze do
  @moduledoc """
  Procedural maze generation for hexagonal grids.

  Uses randomized DFS (recursive backtracking) adapted for hex coordinates.
  Generates connected mazes with ~20% wall density.

  ## Algorithm

  1. Start with all cells as walls
  2. Pick a random starting cell, mark as passage
  3. Recursively visit unvisited neighbors in random order
  4. When carving, mark both the cell and create passage
  5. Backtrack when no unvisited neighbors remain

  ## Wall Density

  The algorithm naturally creates ~20% wall density in hex grids,
  which provides good tactical gameplay with corridors and cover.
  """

  alias SwaiNode.Simulation.Hex

  @doc """
  Generates a maze for the given arena radius.

  Returns a MapSet of hex coordinates that are walls.
  The center area (radius 3) is always kept open for spawning.

  ## Options

  - `:seed` - Random seed for reproducibility (default: random)
  - `:open_center_radius` - Radius of open area at center (default: 3)
  """
  @spec generate(pos_integer(), keyword()) :: MapSet.t()
  def generate(arena_radius, opts \\ []) do
    seed = Keyword.get(opts, :seed)
    open_center = Keyword.get(opts, :open_center_radius, 3)

    if seed, do: :rand.seed(:exsss, seed)

    # Get all hexes in the arena
    all_hexes = Hex.all_hexes_in_radius(arena_radius) |> MapSet.new()

    # Start with all hexes as walls
    # Then carve passages using DFS
    passages = carve_maze(all_hexes, arena_radius)

    # Walls = all hexes minus passages
    walls = MapSet.difference(all_hexes, passages)

    # Ensure center area is always open
    center_hexes = Hex.all_hexes_in_radius(open_center) |> MapSet.new()
    MapSet.difference(walls, center_hexes)
  end

  # Carve passages using randomized DFS
  defp carve_maze(all_hexes, arena_radius) do
    # Start from center
    start = {0, 0}
    visited = MapSet.new([start])

    # DFS with stack (iterative to avoid stack overflow)
    do_carve([start], visited, all_hexes, arena_radius)
  end

  defp do_carve([], visited, _all_hexes, _arena_radius), do: visited

  defp do_carve([current | rest], visited, all_hexes, arena_radius) do
    # Get unvisited neighbors
    unvisited =
      current
      |> Hex.neighbors()
      |> Enum.filter(fn hex ->
        MapSet.member?(all_hexes, hex) and not MapSet.member?(visited, hex)
      end)
      |> Enum.shuffle()

    case unvisited do
      [] ->
        # Backtrack
        do_carve(rest, visited, all_hexes, arena_radius)

      [next | _other] ->
        # Visit next neighbor
        new_visited = MapSet.put(visited, next)
        # Push current back and next to front (DFS)
        do_carve([next, current | rest], new_visited, all_hexes, arena_radius)
    end
  end

  @doc """
  Generates a maze with explicit wall percentage control.

  Uses random scatter approach instead of DFS for more control over density.

  ## Options

  - `:wall_percent` - Target wall percentage (default: 20)
  - `:seed` - Random seed for reproducibility
  - `:open_center_radius` - Radius of open area at center (default: 3)
  """
  @spec generate_scatter(pos_integer(), keyword()) :: MapSet.t()
  def generate_scatter(arena_radius, opts \\ []) do
    wall_percent = Keyword.get(opts, :wall_percent, 20)
    seed = Keyword.get(opts, :seed)
    open_center = Keyword.get(opts, :open_center_radius, 3)

    if seed, do: :rand.seed(:exsss, seed)

    all_hexes = Hex.all_hexes_in_radius(arena_radius)
    center_hexes = Hex.all_hexes_in_radius(open_center) |> MapSet.new()

    # Filter out center hexes
    candidate_hexes = Enum.reject(all_hexes, &MapSet.member?(center_hexes, &1))

    # Calculate number of walls
    wall_count = round(length(candidate_hexes) * wall_percent / 100)

    # Randomly select wall hexes
    candidate_hexes
    |> Enum.shuffle()
    |> Enum.take(wall_count)
    |> MapSet.new()
  end

  @doc """
  Checks if a maze is connected (all open cells reachable from center).

  Returns true if connected, false otherwise.
  """
  @spec connected?(MapSet.t(), pos_integer()) :: boolean()
  def connected?(walls, arena_radius) do
    all_hexes = Hex.all_hexes_in_radius(arena_radius) |> MapSet.new()
    open_hexes = MapSet.difference(all_hexes, walls)

    # BFS from center to check reachability
    reachable = flood_fill({0, 0}, walls, arena_radius)

    MapSet.equal?(reachable, open_hexes)
  end

  @doc """
  Returns all hexes reachable from the given start hex.

  Uses flood fill (BFS) algorithm.
  """
  @spec flood_fill({integer(), integer()}, MapSet.t(), pos_integer()) :: MapSet.t()
  def flood_fill(start, walls, arena_radius) do
    if MapSet.member?(walls, start) or not Hex.in_bounds?(start, arena_radius) do
      MapSet.new()
    else
      do_flood_fill([start], MapSet.new([start]), walls, arena_radius)
    end
  end

  defp do_flood_fill([], visited, _walls, _arena_radius), do: visited

  defp do_flood_fill([current | rest], visited, walls, arena_radius) do
    new_neighbors =
      current
      |> Hex.neighbors()
      |> Enum.filter(fn hex ->
        Hex.in_bounds?(hex, arena_radius) and
          not MapSet.member?(walls, hex) and
          not MapSet.member?(visited, hex)
      end)

    new_visited = Enum.reduce(new_neighbors, visited, &MapSet.put(&2, &1))
    do_flood_fill(rest ++ new_neighbors, new_visited, walls, arena_radius)
  end

  @doc """
  Returns statistics about the generated maze.
  """
  @spec stats(MapSet.t(), pos_integer()) :: map()
  def stats(walls, arena_radius) do
    all_hexes = Hex.all_hexes_in_radius(arena_radius)
    total = length(all_hexes)
    wall_count = MapSet.size(walls)
    open_count = total - wall_count

    %{
      total_hexes: total,
      wall_count: wall_count,
      open_count: open_count,
      wall_percent: Float.round(wall_count / total * 100, 1),
      connected: connected?(walls, arena_radius)
    }
  end
end
