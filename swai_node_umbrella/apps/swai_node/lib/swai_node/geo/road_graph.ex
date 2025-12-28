defmodule SwaiNode.Geo.RoadGraph do
  @moduledoc """
  Graph data structure for road network with A* pathfinding.

  The graph consists of:
  - Nodes: Intersections and endpoints (OSM node IDs -> {lat, lon})
  - Edges: Road segments connecting nodes (adjacency list)
  - Segments: Full polyline data for each road (for rendering)
  """

  require Logger

  defstruct [
    :nodes,      # %{node_id => {lat, lon}}
    :edges,      # %{node_id => [{neighbor_id, distance_m, way_id}]}
    :segments,   # %{way_id => %{points: [{lat, lon}], highway: type}}
    :bbox,       # {min_lat, min_lon, max_lat, max_lon}
    :center      # {lat, lon}
  ]

  @doc """
  Build a graph from Overpass API response data.
  """
  def build(nodes, ways, center) do
    # Filter nodes to only those used in ways
    used_node_ids = ways |> Enum.flat_map(& &1.node_ids) |> MapSet.new()
    filtered_nodes = Map.filter(nodes, fn {id, _} -> MapSet.member?(used_node_ids, id) end)

    # Build edges (adjacency list)
    edges = build_edges(ways, filtered_nodes)

    # Build segments for rendering
    segments = build_segments(ways, nodes)

    # Calculate bounding box
    bbox = calculate_bbox(filtered_nodes)

    graph = %__MODULE__{
      nodes: filtered_nodes,
      edges: edges,
      segments: segments,
      bbox: bbox,
      center: center
    }

    Logger.info("[RoadGraph] Built graph: #{map_size(filtered_nodes)} nodes, #{map_size(edges)} edge lists, #{map_size(segments)} segments")

    graph
  end

  @doc """
  Find shortest path between two nodes using A* algorithm.
  Returns {:ok, path} or {:error, :no_path}

  Path is a list of {lat, lon} coordinates.
  """
  def find_path(%__MODULE__{} = graph, from_node_id, to_node_id) do
    case a_star(graph, from_node_id, to_node_id) do
      {:ok, node_path} ->
        # Convert node IDs to coordinates
        coord_path = Enum.map(node_path, &Map.get(graph.nodes, &1))
        {:ok, coord_path}

      :no_path ->
        {:error, :no_path}
    end
  end

  @doc """
  Get a random node from the graph.
  """
  def random_node(%__MODULE__{nodes: nodes}) do
    nodes
    |> Map.keys()
    |> Enum.random()
  end

  @doc """
  Get coordinates for a node.
  """
  def get_node_coords(%__MODULE__{nodes: nodes}, node_id) do
    Map.get(nodes, node_id)
  end

  @doc """
  Get a random point on any road segment.
  Returns {lat, lon, nearest_node_id}
  """
  def random_road_point(%__MODULE__{segments: segments} = graph) do
    # Pick a random segment
    {_way_id, segment} = Enum.random(segments)
    points = segment.points

    # Pick a random point along the segment
    idx = :rand.uniform(length(points)) - 1
    {lat, lon} = Enum.at(points, idx)

    # Find nearest node
    nearest_node_id = find_nearest_node(graph, lat, lon)

    {lat, lon, nearest_node_id}
  end

  @doc """
  Get a random road point within radius_m of a given coordinate.
  Used for initial spawning clustered around origin.
  Returns {lat, lon, nearest_node_id} or nil if no roads nearby.
  """
  def random_road_point_near(%__MODULE__{segments: segments} = graph, center_lat, center_lon, radius_m) do
    # Find all segment points within radius
    nearby_points =
      segments
      |> Enum.flat_map(fn {_way_id, segment} ->
        segment.points
        |> Enum.filter(fn {lat, lon} ->
          haversine_distance(lat, lon, center_lat, center_lon) <= radius_m
        end)
      end)

    case nearby_points do
      [] ->
        # No roads within radius, snap center to nearest road
        snap_to_road(graph, center_lat, center_lon)

      points ->
        # Pick random point from nearby
        {lat, lon} = Enum.random(points)
        nearest_node_id = find_nearest_node(graph, lat, lon)
        {lat, lon, nearest_node_id}
    end
  end

  @doc """
  Get a random road point near a given node.
  Used for breeding - child spawns near parent.
  Returns {lat, lon, node_id}
  """
  def random_road_point_near_node(%__MODULE__{nodes: nodes, edges: edges} = graph, node_id, radius_m) do
    case Map.get(nodes, node_id) do
      nil ->
        # Unknown node, fall back to random
        random_road_point(graph)

      {node_lat, node_lon} ->
        # Get connected nodes (neighbors)
        neighbors = Map.get(edges, node_id, [])

        # Collect candidate points: the node itself + points along edges to neighbors
        candidates =
          [{node_lat, node_lon, node_id}] ++
            Enum.flat_map(neighbors, fn {neighbor_id, _dist, _way_id} ->
              case Map.get(nodes, neighbor_id) do
                nil ->
                  []

                {n_lat, n_lon} ->
                  # Generate points along the edge
                  points_along_edge(node_lat, node_lon, n_lat, n_lon, radius_m)
                  |> Enum.map(fn {lat, lon} ->
                    nearest = find_nearest_node(graph, lat, lon)
                    {lat, lon, nearest}
                  end)
              end
            end)

        # Filter to within radius and pick random
        nearby =
          candidates
          |> Enum.filter(fn {lat, lon, _} ->
            haversine_distance(lat, lon, node_lat, node_lon) <= radius_m
          end)

        case nearby do
          [] -> {node_lat, node_lon, node_id}
          points -> Enum.random(points)
        end
    end
  end

  # Generate evenly spaced points along an edge, up to max_dist from start
  defp points_along_edge(lat1, lon1, lat2, lon2, max_dist) do
    total_dist = haversine_distance(lat1, lon1, lat2, lon2)
    steps = max(1, trunc(min(total_dist, max_dist) / 5))  # Point every ~5 meters

    Enum.map(0..steps, fn i ->
      t = i / steps
      lat = lat1 + t * (lat2 - lat1)
      lon = lon1 + t * (lon2 - lon1)
      {lat, lon}
    end)
  end

  @doc """
  Find the nearest node to a coordinate.
  """
  def find_nearest_node(%__MODULE__{nodes: nodes}, lat, lon) do
    nodes
    |> Enum.min_by(fn {_id, {nlat, nlon}} ->
      haversine_distance(lat, lon, nlat, nlon)
    end)
    |> elem(0)
  end

  @doc """
  Snap a coordinate to the nearest road.
  Returns {snapped_lat, snapped_lon, nearest_node_id}
  """
  def snap_to_road(%__MODULE__{segments: segments} = graph, lat, lon) do
    # Find nearest point on any segment
    {nearest_lat, nearest_lon, _dist} =
      segments
      |> Enum.flat_map(fn {_way_id, segment} ->
        segment.points
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [{lat1, lon1}, {lat2, lon2}] ->
          {plat, plon} = nearest_point_on_segment(lat, lon, lat1, lon1, lat2, lon2)
          dist = haversine_distance(lat, lon, plat, plon)
          {plat, plon, dist}
        end)
      end)
      |> Enum.min_by(fn {_, _, dist} -> dist end)

    nearest_node_id = find_nearest_node(graph, nearest_lat, nearest_lon)

    {nearest_lat, nearest_lon, nearest_node_id}
  end

  # ============================================================================
  # Private: Graph Building
  # ============================================================================

  defp build_edges(ways, nodes) do
    ways
    |> Enum.reduce(%{}, fn way, edges_acc ->
      node_ids = way.node_ids

      # Create edges between consecutive nodes
      node_ids
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.reduce(edges_acc, fn [from_id, to_id], acc ->
        case {Map.get(nodes, from_id), Map.get(nodes, to_id)} do
          {nil, _} -> acc
          {_, nil} -> acc
          {{lat1, lon1}, {lat2, lon2}} ->
            dist = haversine_distance(lat1, lon1, lat2, lon2)

            # Add edge in both directions (unless oneway)
            acc = add_edge(acc, from_id, to_id, dist, way.id)

            if way.oneway do
              acc
            else
              add_edge(acc, to_id, from_id, dist, way.id)
            end
        end
      end)
    end)
  end

  defp add_edge(edges, from, to, dist, way_id) do
    edge = {to, dist, way_id}
    Map.update(edges, from, [edge], &[edge | &1])
  end

  defp build_segments(ways, nodes) do
    ways
    |> Enum.reduce(%{}, fn way, acc ->
      points =
        way.node_ids
        |> Enum.map(&Map.get(nodes, &1))
        |> Enum.reject(&is_nil/1)

      if length(points) >= 2 do
        Map.put(acc, way.id, %{
          points: points,
          highway: way.highway,
          name: way.name
        })
      else
        acc
      end
    end)
  end

  defp calculate_bbox(nodes) do
    coords = Map.values(nodes)

    if coords == [] do
      {0.0, 0.0, 0.0, 0.0}
    else
      lats = Enum.map(coords, &elem(&1, 0))
      lons = Enum.map(coords, &elem(&1, 1))

      {Enum.min(lats), Enum.min(lons), Enum.max(lats), Enum.max(lons)}
    end
  end

  # ============================================================================
  # Private: A* Pathfinding
  # ============================================================================

  defp a_star(graph, start, goal) do
    # Priority queue: [{f_score, node_id, path}]
    initial = [{heuristic(graph, start, goal), start, [start]}]
    visited = MapSet.new()

    a_star_loop(graph, goal, initial, visited, %{start => 0})
  end

  defp a_star_loop(_graph, _goal, [], _visited, _g_scores), do: :no_path

  defp a_star_loop(graph, goal, open, visited, g_scores) do
    # Get node with lowest f_score
    [{_f, current, path} | rest] = Enum.sort_by(open, &elem(&1, 0))

    cond do
      current == goal ->
        {:ok, Enum.reverse(path)}

      MapSet.member?(visited, current) ->
        a_star_loop(graph, goal, rest, visited, g_scores)

      true ->
        visited = MapSet.put(visited, current)
        neighbors = Map.get(graph.edges, current, [])

        {new_open, new_g_scores} =
          Enum.reduce(neighbors, {rest, g_scores}, fn {neighbor, dist, _way_id}, {open_acc, g_acc} ->
            if MapSet.member?(visited, neighbor) do
              {open_acc, g_acc}
            else
              tentative_g = Map.get(g_acc, current, :infinity) + dist

              if tentative_g < Map.get(g_acc, neighbor, :infinity) do
                f = tentative_g + heuristic(graph, neighbor, goal)
                new_entry = {f, neighbor, [neighbor | path]}
                {[new_entry | open_acc], Map.put(g_acc, neighbor, tentative_g)}
              else
                {open_acc, g_acc}
              end
            end
          end)

        a_star_loop(graph, goal, new_open, visited, new_g_scores)
    end
  end

  defp heuristic(graph, node_id, goal_id) do
    case {Map.get(graph.nodes, node_id), Map.get(graph.nodes, goal_id)} do
      {{lat1, lon1}, {lat2, lon2}} -> haversine_distance(lat1, lon1, lat2, lon2)
      _ -> 0
    end
  end

  # ============================================================================
  # Private: Geometry Helpers
  # ============================================================================

  @earth_radius_m 6_371_000

  defp haversine_distance(lat1, lon1, lat2, lon2) do
    dlat = (lat2 - lat1) * :math.pi() / 180
    dlon = (lon2 - lon1) * :math.pi() / 180

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(lat1 * :math.pi() / 180) * :math.cos(lat2 * :math.pi() / 180) *
          :math.sin(dlon / 2) * :math.sin(dlon / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))

    @earth_radius_m * c
  end

  defp nearest_point_on_segment(px, py, x1, y1, x2, y2) do
    dx = x2 - x1
    dy = y2 - y1

    if dx == 0 and dy == 0 do
      {x1, y1}
    else
      t = max(0, min(1, ((px - x1) * dx + (py - y1) * dy) / (dx * dx + dy * dy)))
      {x1 + t * dx, y1 + t * dy}
    end
  end
end
