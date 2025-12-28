defmodule SwaiNode.Geo.OverpassClient do
  @moduledoc """
  Client for OpenStreetMap Overpass API.
  Fetches road network data for a given bounding box.
  """

  require Logger

  @overpass_url "https://overpass-api.de/api/interpreter"
  @timeout 30_000

  @doc """
  Fetch roads within a bounding box.

  Returns {:ok, %{nodes: nodes, ways: ways}} or {:error, reason}

  ## Parameters
    - min_lat, min_lon, max_lat, max_lon: Bounding box coordinates

  ## Example
      {:ok, data} = OverpassClient.fetch_roads(52.53, 17.57, 52.54, 17.59)
  """
  def fetch_roads(min_lat, min_lon, max_lat, max_lon) do
    query = build_query(min_lat, min_lon, max_lat, max_lon)

    Logger.info("[OverpassClient] Fetching roads for bbox: #{min_lat},#{min_lon},#{max_lat},#{max_lon}")

    case Req.post(@overpass_url, body: query, receive_timeout: @timeout) do
      {:ok, %{status: 200, body: body}} ->
        parse_response(body)

      {:ok, %{status: status, body: body}} ->
        Logger.error("[OverpassClient] API error: status=#{status}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("[OverpassClient] Request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Fetch roads within a radius of a center point.

  ## Parameters
    - lat, lon: Center coordinates
    - radius_m: Radius in meters
  """
  def fetch_roads_around(lat, lon, radius_m) do
    # Convert radius to approximate degree offset
    # 1 degree latitude ≈ 111,320 meters
    # 1 degree longitude ≈ 111,320 * cos(lat) meters
    lat_offset = radius_m / 111_320
    lon_offset = radius_m / (111_320 * :math.cos(lat * :math.pi() / 180))

    min_lat = lat - lat_offset
    max_lat = lat + lat_offset
    min_lon = lon - lon_offset
    max_lon = lon + lon_offset

    fetch_roads(min_lat, min_lon, max_lat, max_lon)
  end

  # Build Overpass QL query for roads
  defp build_query(min_lat, min_lon, max_lat, max_lon) do
    bbox = "#{min_lat},#{min_lon},#{max_lat},#{max_lon}"

    """
    [out:json][timeout:25];
    (
      way["highway"~"^(primary|secondary|tertiary|residential|unclassified|living_street|pedestrian|footway|path|service)$"](#{bbox});
    );
    out body;
    >;
    out skel qt;
    """
  end

  # Parse Overpass JSON response into nodes and ways
  defp parse_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> parse_response(parsed)
      {:error, reason} -> {:error, {:json_parse_error, reason}}
    end
  end

  defp parse_response(%{"elements" => elements}) do
    {nodes, ways} =
      Enum.reduce(elements, {%{}, []}, fn element, {nodes_acc, ways_acc} ->
        case element do
          %{"type" => "node", "id" => id, "lat" => lat, "lon" => lon} ->
            {Map.put(nodes_acc, id, {lat, lon}), ways_acc}

          %{"type" => "way", "id" => id, "nodes" => node_ids} = way ->
            way_data = %{
              id: id,
              node_ids: node_ids,
              highway: get_in(way, ["tags", "highway"]),
              name: get_in(way, ["tags", "name"]),
              oneway: get_in(way, ["tags", "oneway"]) == "yes"
            }
            {nodes_acc, [way_data | ways_acc]}

          _ ->
            {nodes_acc, ways_acc}
        end
      end)

    Logger.info("[OverpassClient] Parsed #{map_size(nodes)} nodes, #{length(ways)} ways")

    {:ok, %{nodes: nodes, ways: ways}}
  end

  defp parse_response(_), do: {:error, :invalid_response}
end
