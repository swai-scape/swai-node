defmodule SwaiNode.DomainSDK.Sensors.StateSensor do
  @moduledoc """
  Proprioceptive state sensor for internal awareness.

  Provides normalized readings of internal state:
  - Energy level (0-1)
  - Age (0-1)
  - Signal strength (0-1)
  - Generation (0-1)

  Total: 4 input values
  """

  @behaviour :agent_sensor

  @channels 4
  @max_energy 300.0
  @max_age 1000.0
  @max_generation 100.0

  @impl :agent_sensor
  def name, do: <<"state">>

  @impl :agent_sensor
  def input_count, do: @channels

  @impl :agent_sensor
  def read(agent_state, _env_state) do
    energy = Map.get(agent_state, :energy, 100.0)
    age = Map.get(agent_state, :age, 0)
    signal = Map.get(agent_state, :signal, 0.0)
    generation = Map.get(agent_state, :generation, 0)

    [
      min(energy / @max_energy, 1.0),
      min(age / @max_age, 1.0),
      signal,
      min(generation / @max_generation, 1.0)
    ]
  end
end
