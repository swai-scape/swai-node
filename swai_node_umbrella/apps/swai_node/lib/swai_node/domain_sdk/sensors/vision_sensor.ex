defmodule SwaiNode.DomainSDK.Sensors.VisionSensor do
  @moduledoc """
  Vision sensor for hex-based agents.

  Casts 6 rays in hex directions, each detecting 3 channels:
  - Food distance (inverse linear)
  - Agent distance (inverse linear)
  - Wall distance (inverse linear)

  Total: 18 input values (6 rays × 3 channels)
  """

  @behaviour :agent_sensor

  alias SwaiNode.Simulation.HexVision

  @channels 18  # 6 rays × 3 channels

  @impl :agent_sensor
  def name, do: <<"vision">>

  @impl :agent_sensor
  def input_count, do: @channels

  @impl :agent_sensor
  def read(agent_state, env_state) do
    hex = Map.get(agent_state, :hex, {0, 0})
    food = Map.get(env_state, :food, %{})
    walls = Map.get(env_state, :walls, MapSet.new())
    agents = Map.get(env_state, :agents, %{})
    arena_radius = Map.get(env_state, :arena_radius, 40)

    # Cast 6 rays, each returning [food_dist, agent_dist, wall_dist]
    HexVision.cast_rays(hex, Map.values(agents), food, walls, arena_radius)
  end
end
