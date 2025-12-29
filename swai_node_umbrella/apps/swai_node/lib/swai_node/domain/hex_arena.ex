defmodule SwaiNode.Domain.HexArena do
  @moduledoc """
  Domain definition for the Hex Arena neuroevolution environment.

  This module defines:
  - Agent structure (sensors, actuators, state)
  - Environment parameters
  - Reward functions
  - Network topology requirements

  ## Agent Sensors (29 inputs)

  | Sensor          | Channels | Description                           |
  |-----------------|----------|---------------------------------------|
  | Vision          | 18       | 6 rays × 3 channels (food/agent/wall) |
  | Hearing         | 4        | Nearby agent signals (directional)    |
  | Smell           | 3        | Food density, agent density, danger   |
  | Internal State  | 4        | Energy, age, signal, health           |

  ## Agent Actuators (9 outputs)

  | Actuator        | Channels | Description                           |
  |-----------------|----------|---------------------------------------|
  | Movement        | 7        | 6 directions + stay                   |
  | Signal          | 1        | Broadcast signal strength             |
  | Attack          | 1        | Attack intention                      |

  ## Reward Function

  Fitness = survival_score + food_score + kill_score
  - survival_score = ticks_survived × 0.5
  - food_score = food_eaten × 50.0
  - kill_score = kills × 100.0
  """

  # ===========================================================================
  # Network Topology
  # ===========================================================================

  @doc "Number of input neurons (sensors)"
  def input_count, do: 29

  @doc "Hidden layer configuration"
  def hidden_layers, do: [32, 16]

  @doc "Number of output neurons (actuators)"
  def output_count, do: 9

  @doc "Full network topology tuple"
  def network_topology, do: {input_count(), hidden_layers(), output_count()}

  # ===========================================================================
  # Sensor Definitions
  # ===========================================================================

  @doc "Vision sensor: 6 rays × 3 channels"
  def vision_channels, do: 18

  @doc "Hearing sensor: 4 directional channels"
  def hearing_channels, do: 4

  @doc "Smell sensor: 3 channels (food, agents, danger)"
  def smell_channels, do: 3

  @doc "Internal state: 4 channels (energy, age, signal, health)"
  def state_channels, do: 4

  # ===========================================================================
  # Actuator Definitions
  # ===========================================================================

  @doc "Movement outputs: 6 directions + stay"
  def movement_outputs, do: 7

  @doc "Signal output: 1 channel"
  def signal_outputs, do: 1

  @doc "Attack output: 1 channel"
  def attack_outputs, do: 1

  # ===========================================================================
  # Environment Parameters
  # ===========================================================================

  @doc "Default arena radius in hex cells"
  def default_arena_radius, do: 40

  @doc "Wall density percentage"
  def wall_percent, do: 10

  @doc "Open center radius (spawn area)"
  def open_center_radius, do: 5

  @doc "Maximum food items in arena"
  def max_food, do: 80

  @doc "Food spawn probability per tick"
  def food_spawn_rate, do: 0.8

  # ===========================================================================
  # Agent Parameters
  # ===========================================================================

  @doc "Starting energy for new agents"
  def starting_energy, do: 150.0

  @doc "Maximum energy capacity"
  def max_energy, do: 300.0

  @doc "Energy cost per move"
  def move_cost, do: 0.3

  @doc "Energy gained from eating food"
  def eat_gain, do: 40.0

  # ===========================================================================
  # Reward Function
  # ===========================================================================

  @doc """
  Calculate fitness from evaluation metrics.

  ## Weights
  - Survival: 0.5 points per tick
  - Food: 50.0 points per food eaten
  - Kills: 100.0 points per kill
  """
  def calculate_fitness(metrics) when is_map(metrics) do
    ticks = Map.get(metrics, :ticks_survived, 0)
    food = Map.get(metrics, :food_eaten, 0)
    kills = Map.get(metrics, :kills, 0)

    survival_score = ticks * 0.5
    food_score = food * 50.0
    kill_score = kills * 100.0

    survival_score + food_score + kill_score
  end

  def calculate_fitness(_), do: 0.0

  @doc "Fitness weights for component breakdown"
  def fitness_weights do
    %{
      survival_per_tick: 0.5,
      food_eaten: 50.0,
      kills: 100.0
    }
  end

  # ===========================================================================
  # Agent Structure
  # ===========================================================================

  @doc """
  Create a new agent struct with default values.
  """
  def new_agent(opts \\ []) do
    %{
      id: Keyword.get(opts, :id, make_ref()),
      hex: Keyword.get(opts, :hex, {0, 0}),
      energy: Keyword.get(opts, :energy, starting_energy()),
      age: 0,
      signal: 0.5,
      generation: Keyword.get(opts, :generation, 0),
      food_eaten: 0,
      kills: 0,
      network: Keyword.get(opts, :network),
      last_direction: nil
    }
  end

  @doc """
  Agent sensor specification for documentation.
  """
  def sensor_spec do
    [
      {:vision, vision_channels(), "6 rays × 3 channels (food dist, agent dist, wall dist)"},
      {:hearing, hearing_channels(), "4 directional signal channels"},
      {:smell, smell_channels(), "food density, agent density, danger level"},
      {:state, state_channels(), "normalized energy, age, signal, health"}
    ]
  end

  @doc """
  Agent actuator specification for documentation.
  """
  def actuator_spec do
    [
      {:movement, movement_outputs(), "6 hex directions + stay (softmax)"},
      {:signal, signal_outputs(), "broadcast signal strength (0-1)"},
      {:attack, attack_outputs(), "attack intention (threshold)"}
    ]
  end
end
