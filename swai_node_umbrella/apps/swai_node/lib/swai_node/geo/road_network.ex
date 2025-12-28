defmodule SwaiNode.Geo.RoadNetwork do
  @moduledoc """
  Road network manager for street-following agents.

  Fetches road data from OpenStreetMap, builds a graph,
  and provides APIs for pathfinding and road-based positioning.

  Uses ETS for caching the road graph.
  """

  use GenServer
  require Logger

  alias SwaiNode.Geo.{OverpassClient, RoadGraph}

  @table :road_network_cache
  @default_radius_m 500

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Load road network for a location.
  Fetches from OpenStreetMap if not cached.
  """
  def load(lat, lon, radius_m \\ @default_radius_m) do
    GenServer.call(__MODULE__, {:load, lat, lon, radius_m}, 60_000)
  end

  @doc """
  Get the current road graph.
  Returns nil if not loaded.
  """
  def get_graph do
    case :ets.lookup(@table, :graph) do
      [{:graph, graph}] -> graph
      [] -> nil
    end
  end

  @doc """
  Check if road network is loaded.
  """
  def loaded? do
    get_graph() != nil
  end

  @doc """
  Get a random point on a road.
  Returns {lat, lon, node_id} or nil if not loaded.
  """
  def random_road_point do
    case get_graph() do
      nil -> nil
      graph -> RoadGraph.random_road_point(graph)
    end
  end

  @doc """
  Get a random road point within radius_m of a coordinate.
  Used for initial spawning clustered around origin.
  Returns {lat, lon, node_id} or nil if not loaded.
  """
  def random_road_point_near(lat, lon, radius_m \\ 50) do
    case get_graph() do
      nil -> nil
      graph -> RoadGraph.random_road_point_near(graph, lat, lon, radius_m)
    end
  end

  @doc """
  Get a random road point near a given node.
  Used for breeding - child spawns near parent.
  Returns {lat, lon, node_id} or nil if not loaded.
  """
  def random_road_point_near_node(node_id, radius_m \\ 20) do
    case get_graph() do
      nil -> nil
      graph -> RoadGraph.random_road_point_near_node(graph, node_id, radius_m)
    end
  end

  @doc """
  Get a random intersection node.
  Returns node_id or nil if not loaded.
  """
  def random_node do
    case get_graph() do
      nil -> nil
      graph -> RoadGraph.random_node(graph)
    end
  end

  @doc """
  Get coordinates for a node.
  """
  def get_node_coords(node_id) do
    case get_graph() do
      nil -> nil
      graph -> RoadGraph.get_node_coords(graph, node_id)
    end
  end

  @doc """
  Find path between two nodes.
  Returns {:ok, [{lat, lon}, ...]} or {:error, reason}
  """
  def find_path(from_node_id, to_node_id) do
    case get_graph() do
      nil -> {:error, :not_loaded}
      graph -> RoadGraph.find_path(graph, from_node_id, to_node_id)
    end
  end

  @doc """
  Snap a coordinate to the nearest road.
  Returns {lat, lon, node_id} or nil if not loaded.
  """
  def snap_to_road(lat, lon) do
    case get_graph() do
      nil -> nil
      graph -> RoadGraph.snap_to_road(graph, lat, lon)
    end
  end

  @doc """
  Find the nearest node to a coordinate.
  """
  def find_nearest_node(lat, lon) do
    case get_graph() do
      nil -> nil
      graph -> RoadGraph.find_nearest_node(graph, lat, lon)
    end
  end

  @doc """
  Get all road segments for rendering.
  Returns %{way_id => %{points: [{lat, lon}], highway: type}}
  """
  def get_segments do
    case get_graph() do
      nil -> %{}
      graph -> graph.segments
    end
  end

  @doc """
  Get graph statistics.
  """
  def stats do
    case get_graph() do
      nil ->
        %{loaded: false}

      graph ->
        %{
          loaded: true,
          nodes: map_size(graph.nodes),
          edges: map_size(graph.edges),
          segments: map_size(graph.segments),
          bbox: graph.bbox,
          center: graph.center
        }
    end
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Create ETS table for caching
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

    Logger.info("[RoadNetwork] Started")

    # Auto-load roads if configured
    geo_config = Application.get_env(:swai_node, :geo, [])

    if Keyword.get(geo_config, :auto_load_roads, false) do
      send(self(), :auto_load)
    end

    {:ok, %{loading: false}}
  end

  @impl true
  def handle_info(:auto_load, state) do
    geo_config = Application.get_env(:swai_node, :geo, [])
    lat = Keyword.get(geo_config, :latitude, 52.5347)
    lon = Keyword.get(geo_config, :longitude, 17.5828)
    radius = Keyword.get(geo_config, :road_network_radius_m, 500)

    Logger.info("[RoadNetwork] Auto-loading roads around #{lat}, #{lon} (radius: #{radius}m)")

    case OverpassClient.fetch_roads_around(lat, lon, radius) do
      {:ok, %{nodes: nodes, ways: ways}} ->
        graph = RoadGraph.build(nodes, ways, {lat, lon})
        :ets.insert(@table, {:graph, graph})
        Logger.info("[RoadNetwork] Auto-load complete: #{map_size(graph.nodes)} nodes, #{map_size(graph.segments)} segments")

      {:error, reason} ->
        Logger.error("[RoadNetwork] Auto-load failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:load, lat, lon, radius_m}, _from, state) do
    if state.loading do
      {:reply, {:error, :already_loading}, state}
    else
      Logger.info("[RoadNetwork] Loading roads around #{lat}, #{lon} (radius: #{radius_m}m)")

      case OverpassClient.fetch_roads_around(lat, lon, radius_m) do
        {:ok, %{nodes: nodes, ways: ways}} ->
          graph = RoadGraph.build(nodes, ways, {lat, lon})
          :ets.insert(@table, {:graph, graph})

          Logger.info("[RoadNetwork] Loaded successfully")
          {:reply, :ok, state}

        {:error, reason} ->
          Logger.error("[RoadNetwork] Failed to load: #{inspect(reason)}")
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("[RoadNetwork] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end
end
