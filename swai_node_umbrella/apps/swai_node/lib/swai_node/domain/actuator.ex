defmodule SwaiNode.Domain.Actuator do
  @moduledoc """
  Actuator translates neural network outputs into validated commands.

  This is the bridge between the neural network's intentions and the world.
  The actuator validates commands against world constraints and produces events.

  ## Movement Actuator

  Network outputs 7 direction preferences: [E, NE, NW, W, SW, SE, STAY]
  Actuator picks the highest-preference VALID direction and emits an event.

  ## Flow

      Network outputs → Actuator.move/4 → {:ok, event} | {:error, reason}
  """

  alias SwaiNode.Domain.Events
  alias SwaiNode.Simulation.Hex

  # Momentum bonus for continuing in the same direction
  @momentum_bonus 0.15
  # Exploration penalty for STAY to encourage movement during visualization
  @stay_penalty 0.20

  @doc """
  Process movement actuator output.

  Takes direction preferences from the network and world constraints,
  returns a movement event.

  ## Parameters
  - agent: agent struct with :id, :hex, :last_direction
  - direction_prefs: list of 7 floats [E, NE, NW, W, SW, SE, STAY]
  - world: map with :walls, :arena_radius, :occupied, :tick

  ## Returns
  - {:ok, event} where event is agent_moved or agent_stayed
  """
  @spec move(map(), list(float()), map()) :: {:ok, map()}
  def move(agent, direction_prefs, world) when length(direction_prefs) == 7 do
    %{walls: walls, arena_radius: arena_radius, occupied: occupied, tick: tick} = world
    last_dir = Map.get(agent, :last_direction)

    # Apply momentum bonus to last direction and exploration penalty to STAY
    prefs_with_momentum = apply_momentum(direction_prefs, last_dir)
    prefs_adjusted = apply_stay_penalty(prefs_with_momentum)

    # Find best valid direction
    {chosen_dir, new_hex} = find_best_direction(
      agent.hex,
      prefs_adjusted,
      walls,
      arena_radius,
      occupied
    )

    # Only emit event if position changed
    if new_hex == agent.hex do
      {:ok, nil}  # No movement, no event
    else
      {:ok, Events.agent_moved(agent.id, agent.hex, new_hex, chosen_dir, tick)}
    end
  end

  # Apply momentum bonus to favor continuing in the same direction
  defp apply_momentum(prefs, nil), do: prefs
  defp apply_momentum(prefs, last_dir) when last_dir >= 6, do: prefs
  defp apply_momentum(prefs, last_dir) do
    prefs
    |> Enum.with_index()
    |> Enum.map(fn {pref, idx} ->
      if idx == last_dir, do: pref + @momentum_bonus, else: pref
    end)
  end

  # Apply penalty to STAY to encourage exploration
  defp apply_stay_penalty(prefs) do
    prefs
    |> Enum.with_index()
    |> Enum.map(fn {pref, idx} ->
      if idx == 6, do: max(0.0, pref - @stay_penalty), else: pref
    end)
  end

  # Find the best valid direction based on preferences
  defp find_best_direction(hex, prefs_with_momentum, walls, arena_radius, occupied) do
    prefs_with_momentum
    |> Enum.with_index()
    |> Enum.filter(fn {_pref, dir} -> valid_direction?(hex, dir, walls, arena_radius, occupied) end)
    |> Enum.max_by(fn {pref, _dir} -> pref end, fn -> {0.0, 6} end)
    |> then(fn {_pref, dir} ->
      new_hex = if dir == 6, do: hex, else: Hex.neighbor(hex, dir)
      {dir, new_hex}
    end)
  end

  # Check if a direction is valid (not blocked by wall, in bounds, not occupied)
  defp valid_direction?(_hex, 6, _walls, _arena_radius, _occupied), do: true
  defp valid_direction?(hex, dir, walls, arena_radius, occupied) do
    target = Hex.neighbor(hex, dir)
    Hex.in_bounds?(target, arena_radius) and
      not MapSet.member?(walls, target) and
      not MapSet.member?(occupied, target)
  end
end
