defmodule SwaiNode.DomainSDK.Sensors.HearingSensor do
  @moduledoc """
  Hearing sensor for detecting nearby agent signals.

  Returns signal values from the 4 nearest agents.
  Agents broadcast signals (0-1) that others can detect.

  Total: 4 input values
  """

  @behaviour :agent_sensor

  @channels 4

  @impl :agent_sensor
  def name, do: <<"hearing">>

  @impl :agent_sensor
  def input_count, do: @channels

  @impl :agent_sensor
  def read(agent_state, env_state) do
    hex = Map.get(agent_state, :hex, {0, 0})
    agent_id = Map.get(agent_state, :id)
    agents = Map.get(env_state, :agents, %{})

    # Get other agents sorted by distance
    signals =
      agents
      |> Map.values()
      |> Enum.reject(fn a -> Map.get(a, :id) == agent_id end)
      |> Enum.map(fn a ->
        other_hex = Map.get(a, :hex, {0, 0})
        signal = Map.get(a, :signal, 0.0)
        {signal, hex_distance(hex, other_hex)}
      end)
      |> Enum.sort_by(fn {_, dist} -> dist end)
      |> Enum.take(@channels)
      |> Enum.map(fn {signal, _} -> signal end)

    # Pad to 4 channels
    pad_list(signals, @channels, 0.0)
  end

  defp hex_distance({q1, r1}, {q2, r2}) do
    dq = abs(q1 - q2)
    dr = abs(r1 - r2)
    ds = abs((q1 + r1) - (q2 + r2))
    max(dq, max(dr, ds))
  end

  defp pad_list(list, length, default) do
    current = length(list)
    if current >= length do
      Enum.take(list, length)
    else
      list ++ List.duplicate(default, length - current)
    end
  end
end
