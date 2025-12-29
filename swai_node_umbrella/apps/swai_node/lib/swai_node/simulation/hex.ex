defmodule SwaiNode.Simulation.Hex do
  @moduledoc """
  Hexagonal grid coordinate utilities using axial coordinates.

  Uses pointy-top hexagons with axial coordinates (q, r).
  The third cube coordinate s = -q - r is derived when needed.

  ## Coordinate System

  ```
       NW   NE
         \\ /
      W -- o -- E
         / \\
       SW   SE
  ```

  ## Directions (0-5)

  - 0: East (+1, 0)
  - 1: Northeast (+1, -1)
  - 2: Northwest (0, -1)
  - 3: West (-1, 0)
  - 4: Southwest (-1, +1)
  - 5: Southeast (0, +1)
  """

  # Direction vectors for pointy-top hexagons in axial coordinates
  # Indexed 0-5: E, NE, NW, W, SW, SE
  @directions [
    {1, 0},   # 0: East
    {1, -1},  # 1: Northeast
    {0, -1},  # 2: Northwest
    {-1, 0},  # 3: West
    {-1, 1},  # 4: Southwest
    {0, 1}    # 5: Southeast
  ]

  @direction_count 6

  # Default hex size for rendering (pixels)
  @default_hex_size 12

  @doc """
  Returns the direction vector for a given direction index (0-5).
  """
  @spec direction(non_neg_integer()) :: {integer(), integer()}
  def direction(dir) when dir >= 0 and dir < @direction_count do
    Enum.at(@directions, dir)
  end

  @doc """
  Returns all 6 direction vectors.
  """
  @spec directions() :: list({integer(), integer()})
  def directions, do: @directions

  @doc """
  Returns the number of directions (6).
  """
  @spec direction_count() :: pos_integer()
  def direction_count, do: @direction_count

  @doc """
  Returns the default hex size in pixels.
  """
  @spec default_hex_size() :: pos_integer()
  def default_hex_size, do: @default_hex_size

  @doc """
  Returns the hex coordinate in the given direction from the origin.
  """
  @spec neighbor({integer(), integer()}, non_neg_integer()) :: {integer(), integer()}
  def neighbor({q, r}, dir) when dir >= 0 and dir < @direction_count do
    {dq, dr} = direction(dir)
    {q + dq, r + dr}
  end

  @doc """
  Returns all 6 neighboring hex coordinates.
  """
  @spec neighbors({integer(), integer()}) :: list({integer(), integer()})
  def neighbors({q, r}) do
    Enum.map(@directions, fn {dq, dr} -> {q + dq, r + dr} end)
  end

  @doc """
  Returns neighboring hexes that are not walls or out of bounds.
  """
  @spec passable_neighbors({integer(), integer()}, MapSet.t(), pos_integer()) ::
          list({integer(), integer()})
  def passable_neighbors(hex, walls, arena_radius) do
    hex
    |> neighbors()
    |> Enum.filter(fn n -> in_bounds?(n, arena_radius) and not MapSet.member?(walls, n) end)
  end

  @doc """
  Calculates the distance between two hexes using cube coordinates.

  Distance = max(|dq|, |dr|, |ds|) where s = -q - r
  """
  @spec distance({integer(), integer()}, {integer(), integer()}) :: non_neg_integer()
  def distance({q1, r1}, {q2, r2}) do
    dq = abs(q1 - q2)
    dr = abs(r1 - r2)
    # s = -q - r, so ds = |(-q1-r1) - (-q2-r2)| = |(q2-q1) + (r2-r1)|
    ds = abs((q2 - q1) + (r2 - r1))
    max(dq, max(dr, ds))
  end

  @doc """
  Checks if a hex is within the arena bounds.

  Arena is hexagonal with given radius from center {0, 0}.
  """
  @spec in_bounds?({integer(), integer()}, pos_integer()) :: boolean()
  def in_bounds?({q, r}, arena_radius) do
    distance({0, 0}, {q, r}) <= arena_radius
  end

  @doc """
  Converts axial coordinates to pixel coordinates for rendering.

  Uses pointy-top orientation.
  Returns {x, y} pixel coordinates relative to center (0, 0).
  """
  @spec to_pixel({integer(), integer()}, pos_integer()) :: {float(), float()}
  def to_pixel({q, r}, hex_size \\ @default_hex_size) do
    x = hex_size * (:math.sqrt(3) * q + :math.sqrt(3) / 2 * r)
    y = hex_size * (3 / 2 * r)
    {x, y}
  end

  @doc """
  Converts pixel coordinates to the nearest axial hex coordinates.

  Uses pointy-top orientation.
  """
  @spec from_pixel({number(), number()}, pos_integer()) :: {integer(), integer()}
  def from_pixel({x, y}, hex_size \\ @default_hex_size) do
    # Fractional axial coordinates
    q = (:math.sqrt(3) / 3 * x - 1 / 3 * y) / hex_size
    r = (2 / 3 * y) / hex_size

    # Round to nearest hex
    cube_round(q, r)
  end

  # Round fractional axial to nearest hex using cube coordinates
  defp cube_round(q, r) do
    s = -q - r

    rq = round(q)
    rr = round(r)
    rs = round(s)

    q_diff = abs(rq - q)
    r_diff = abs(rr - r)
    s_diff = abs(rs - s)

    cond do
      q_diff > r_diff and q_diff > s_diff ->
        {-rr - rs, rr}

      r_diff > s_diff ->
        {rq, -rq - rs}

      true ->
        {rq, rr}
    end
  end

  @doc """
  Returns all hex coordinates within the given arena radius.
  """
  @spec all_hexes_in_radius(pos_integer()) :: list({integer(), integer()})
  def all_hexes_in_radius(radius) do
    for q <- -radius..radius,
        r <- -radius..radius,
        in_bounds?({q, r}, radius),
        do: {q, r}
  end

  @doc """
  Returns a random hex within the arena bounds.
  """
  @spec random_in_bounds(pos_integer()) :: {integer(), integer()}
  def random_in_bounds(arena_radius) do
    # Generate random hex and check bounds
    # Use rejection sampling within a square, accept if in hexagonal bounds
    do_random_in_bounds(arena_radius)
  end

  defp do_random_in_bounds(arena_radius) do
    q = :rand.uniform(arena_radius * 2 + 1) - arena_radius - 1
    r = :rand.uniform(arena_radius * 2 + 1) - arena_radius - 1

    if in_bounds?({q, r}, arena_radius) do
      {q, r}
    else
      do_random_in_bounds(arena_radius)
    end
  end

  @doc """
  Returns a random hex that is not a wall and is within bounds.
  """
  @spec random_open_hex(pos_integer(), MapSet.t()) :: {integer(), integer()} | nil
  def random_open_hex(arena_radius, walls, max_attempts \\ 100) do
    do_random_open_hex(arena_radius, walls, max_attempts)
  end

  defp do_random_open_hex(_arena_radius, _walls, 0), do: nil

  defp do_random_open_hex(arena_radius, walls, attempts) do
    hex = random_in_bounds(arena_radius)

    if MapSet.member?(walls, hex) do
      do_random_open_hex(arena_radius, walls, attempts - 1)
    else
      hex
    end
  end

  @doc """
  Draws a line between two hexes, returning all hexes along the path.

  Uses linear interpolation in cube coordinates.
  """
  @spec line({integer(), integer()}, {integer(), integer()}) :: list({integer(), integer()})
  def line({q1, r1} = from, {q2, r2} = to) do
    n = distance(from, to)

    if n == 0 do
      [from]
    else
      for i <- 0..n do
        t = i / n
        # Linear interpolation
        q = q1 + (q2 - q1) * t
        r = r1 + (r2 - r1) * t
        cube_round(q, r)
      end
    end
  end

  @doc """
  Returns the direction index (0-5) that best matches the direction from one hex to another.
  Returns nil if the hexes are the same.
  """
  @spec direction_to({integer(), integer()}, {integer(), integer()}) :: non_neg_integer() | nil
  def direction_to({q1, r1}, {q2, r2}) do
    dq = q2 - q1
    dr = r2 - r1

    if dq == 0 and dr == 0 do
      nil
    else
      # Find the direction that best matches the delta
      {_dist, dir} =
        @directions
        |> Enum.with_index()
        |> Enum.map(fn {{dir_q, dir_r}, idx} ->
          # Dot product similarity (higher is better match)
          dot = dq * dir_q + dr * dir_r
          {dot, idx}
        end)
        |> Enum.max_by(fn {dot, _} -> dot end)

      dir
    end
  end

  @doc """
  Returns the opposite direction (rotated 180 degrees).
  """
  @spec opposite_direction(non_neg_integer()) :: non_neg_integer()
  def opposite_direction(dir) when dir >= 0 and dir < @direction_count do
    rem(dir + 3, 6)
  end
end
