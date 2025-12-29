defmodule SwaiNode.Domain.Events do
  @moduledoc """
  Domain events for the hex arena simulation.

  Events are facts that happened. They use past tense naming.
  The producer owns the event content; consumers must accept it.
  """

  # ============================================================================
  # Movement Events
  # ============================================================================

  @doc """
  Agent moved from one hex to another.

  - agent_id: unique identifier
  - from_hex: {q, r} axial coordinates
  - to_hex: {q, r} axial coordinates
  - direction: 0-5 (E, NE, NW, W, SW, SE) or 6 (stayed)
  - tick: world tick when this happened
  """
  defstruct [:type, :agent_id, :from_hex, :to_hex, :direction, :tick, :timestamp]

  def agent_moved(agent_id, from_hex, to_hex, direction, tick) do
    %__MODULE__{
      type: :agent_moved,
      agent_id: agent_id,
      from_hex: from_hex,
      to_hex: to_hex,
      direction: direction,
      tick: tick,
      timestamp: System.monotonic_time(:millisecond)
    }
  end


  def agent_ate(agent_id, hex, food_energy, tick) do
    %{
      type: :agent_ate,
      agent_id: agent_id,
      hex: hex,
      food_energy: food_energy,
      tick: tick,
      timestamp: System.monotonic_time(:millisecond)
    }
  end

  def agent_died(agent_id, hex, cause, tick) do
    %{
      type: :agent_died,
      agent_id: agent_id,
      hex: hex,
      cause: cause,
      tick: tick,
      timestamp: System.monotonic_time(:millisecond)
    }
  end

  def agent_spawned(agent_id, hex, network, tick) do
    %{
      type: :agent_spawned,
      agent_id: agent_id,
      hex: hex,
      network: network,
      tick: tick,
      timestamp: System.monotonic_time(:millisecond)
    }
  end
end
