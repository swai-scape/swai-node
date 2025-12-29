defmodule SwaiNode.DomainSDK.Species.ForagerSpecies do
  @moduledoc """
  Forager species - optimized for finding and consuming food.

  Foragers are the baseline species in the hex arena. They have:
  - Broad vision for finding food
  - Smell sensors for detecting food gradients
  - Movement and signaling capabilities
  - No attack ability (peaceful)

  ## Network Topology

  ```
  Inputs (29):
    - Vision: 18 (6 directions × 3 channels: food/wall/agent)
    - Hearing: 4 (signal detection from nearby agents)
    - Smell: 3 (food density gradient)
    - State: 4 (energy, age, signal, generation)

  Hidden: [32, 16]

  Outputs (9):
    - Movement: 7 (6 hex directions + stay)
    - Signal: 1 (broadcast strength)
    - Forage: 1 (eating intention - threshold activated)
  ```

  ## Fitness Function

  Foragers are rewarded for:
  - Survival time (low weight - discourages hiding)
  - Food consumed (high weight - primary objective)
  - Efficiency (food per movement)
  """

  @behaviour :agent_species

  alias SwaiNode.DomainSDK.Sensors.{
    VisionSensor,
    HearingSensor,
    SmellSensor,
    StateSensor
  }

  alias SwaiNode.DomainSDK.Actuators.{
    MovementActuator,
    SignalActuator,
    ForageActuator
  }

  alias SwaiNode.DomainSDK.Evaluators.ForagerFitnessEvaluator

  # Callbacks

  @impl :agent_species
  def name, do: <<"forager">>

  @impl :agent_species
  def version, do: <<"1.0.0">>

  @impl :agent_species
  def network_topology do
    # 29 inputs -> [32, 16] hidden -> 9 outputs
    {29, [32, 16], 9}
  end

  @impl :agent_species
  def sensors do
    [VisionSensor, HearingSensor, SmellSensor, StateSensor]
  end

  @impl :agent_species
  def actuators do
    [MovementActuator, SignalActuator, ForageActuator]
  end

  @impl :agent_species
  def evaluator do
    ForagerFitnessEvaluator
  end

  @impl :agent_species
  def spawn_config do
    %{
      energy: 150.0,
      max_energy: 300.0,
      spawn_zone: :center,
      color: {0.2, 0.8, 0.3},  # Green
      size: 1.0,
      speed: 1.0,
      vision_range: 5,
      metabolism: 0.3  # Energy cost per tick
    }
  end

  @impl :agent_species
  def subspeciation_threshold do
    1.5  # Moderate - allows behavioral diversity
  end

  # Optional mutation config
  @impl :agent_species
  def mutation_config do
    %{
      mutation_rate: 0.1,
      mutation_strength: 0.3,
      add_neuron_rate: 0.03,
      add_connection_rate: 0.05
    }
  end
end
