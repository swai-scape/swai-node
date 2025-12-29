defmodule SwaiNode.DomainSDK.Species.PredatorSpecies do
  @moduledoc """
  Predator species - optimized for hunting other agents.

  Predators are specialized hunters with:
  - Enhanced prey detection (motion, weak signals)
  - Hunting sensor for tracking prey
  - Attack capability
  - Stealth mode to reduce detection
  - Higher metabolism but more energy from kills

  ## Network Topology

  ```
  Inputs (35):
    - Vision: 18 (6 directions × 3 channels: food/wall/agent)
    - Hearing: 4 (signal detection)
    - Hunting: 6 (prey direction, distance, movement)
    - Proprioception: 3 (own speed, heading, stamina)
    - State: 4 (energy, age, signal, generation)

  Hidden: [48, 24]

  Outputs (12):
    - Movement: 7 (6 hex directions + stay)
    - Attack: 1 (attack strength)
    - Stealth: 1 (reduce own signal)
    - Sprint: 1 (speed boost, costs energy)
    - Signal: 1 (intimidation/territory)
    - Eat: 1 (consume killed prey)
  ```

  ## Fitness Function

  Predators are rewarded for:
  - Kills (primary objective)
  - Energy gained from prey
  - Survival time
  - Hunt efficiency (kills per energy spent)
  """

  # Implements :agent_species behaviour (Erlang)

  alias SwaiNode.DomainSDK.Sensors.{
    VisionSensor,
    HearingSensor,
    HuntingSensor,
    ProprioceptionSensor,
    StateSensor
  }

  alias SwaiNode.DomainSDK.Actuators.{
    MovementActuator,
    AttackActuator,
    StealthActuator,
    SprintActuator,
    SignalActuator,
    ConsumeActuator
  }

  alias SwaiNode.DomainSDK.Evaluators.PredatorFitnessEvaluator

  # Callbacks

  def name, do: <<"predator">>

  def version, do: <<"1.0.0">>

  def network_topology do
    # 35 inputs -> [48, 24] hidden -> 12 outputs
    {35, [48, 24], 12}
  end

  def sensors do
    [VisionSensor, HearingSensor, HuntingSensor, ProprioceptionSensor, StateSensor]
  end

  def actuators do
    [MovementActuator, AttackActuator, StealthActuator, SprintActuator, SignalActuator, ConsumeActuator]
  end

  def evaluator do
    PredatorFitnessEvaluator
  end

  def spawn_config do
    %{
      energy: 200.0,
      max_energy: 400.0,
      spawn_zone: :edge,  # Predators spawn at edges
      color: {0.9, 0.2, 0.2},  # Red
      size: 1.2,
      speed: 1.5,  # Faster than foragers
      vision_range: 7,  # Better vision
      metabolism: 0.5,  # Higher energy cost
      attack_damage: 50.0,
      attack_range: 1,  # Adjacent hex
      stealth_cost: 0.2,
      sprint_cost: 1.0,
      sprint_multiplier: 2.0
    }
  end

  def subspeciation_threshold do
    2.0  # Higher threshold - more convergent (hunting is specialized)
  end

  def mutation_config do
    %{
      mutation_rate: 0.15,  # Higher mutation - need to adapt to prey
      mutation_strength: 0.4,
      add_neuron_rate: 0.04,
      add_connection_rate: 0.06
    }
  end
end
