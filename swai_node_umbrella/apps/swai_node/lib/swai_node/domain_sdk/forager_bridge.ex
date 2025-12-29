defmodule SwaiNode.DomainSDK.ForagerBridge do
  @moduledoc """
  Domain SDK bridge for foraging agents in the hex arena.

  This module configures the Domain SDK components and provides
  a clean interface for training agents via neuroevolution.

  ## Components

  - **Agent**: `ForagerAgentDefinition` - Network topology (29→[32,16]→9)
  - **Sensors**: Vision (18), Hearing (4), Smell (3), State (4)
  - **Actuators**: Movement (7), Signal (1), Attack (1)
  - **Environment**: `HexArenaEnvironment` - Episode lifecycle
  - **Evaluator**: `ForagerEvaluator` - Fitness calculation

  ## Usage

  ```elixir
  # Create a bridge configuration
  {:ok, bridge} = ForagerBridge.new()

  # Run a single episode with a network
  {:ok, fitness, metrics} = ForagerBridge.run_episode(bridge, network)

  # Start training
  {:ok, neuro_pid} = ForagerBridge.train(bridge, %{
    population_size: 100,
    max_generations: 50
  })
  ```
  """

  alias SwaiNode.DomainSDK.{
    ForagerAgentDefinition,
    ForagerEvaluator,
    HexArenaEnvironment
  }

  alias SwaiNode.DomainSDK.Sensors.{
    VisionSensor,
    HearingSensor,
    SmellSensor,
    StateSensor
  }

  alias SwaiNode.DomainSDK.Actuators.{
    MovementActuator,
    SignalActuator,
    AttackActuator
  }

  @doc """
  Create a new bridge configuration for foraging agents.

  Returns `{:ok, bridge}` with the configured bridge map.
  """
  def new do
    :agent_bridge.new(%{
      definition: ForagerAgentDefinition,
      sensors: [VisionSensor, HearingSensor, SmellSensor, StateSensor],
      actuators: [MovementActuator, SignalActuator, AttackActuator],
      environment: HexArenaEnvironment,
      evaluator: ForagerEvaluator
    })
  end

  @doc """
  Run a single episode with the given network.

  Returns `{:ok, fitness, metrics}` on success.
  """
  def run_episode(bridge, network, env_config \\ %{}) do
    :agent_bridge.run_episode(bridge, network, env_config)
  end

  @doc """
  Evaluate a network across multiple episodes and return average fitness.
  """
  def evaluate(bridge, network, env_config \\ %{}, episodes \\ 3) do
    :agent_trainer.evaluate_many(bridge, network, env_config, episodes)
  end

  @doc """
  Start neuroevolution training.

  ## Options

  - `:population_size` - Number of individuals (default: 100)
  - `:max_generations` - Stopping condition (default: 100)
  - `:episodes_per_eval` - Episodes to average per fitness (default: 1)
  - `:env_config` - Environment configuration
  """
  def train(bridge, options \\ %{}) do
    :agent_trainer.train(bridge, options)
  end

  @doc """
  Convert bridge to neuroevolution config for manual control.
  """
  def to_neuro_config(bridge, env_config \\ %{}, options \\ %{}) do
    :agent_trainer.to_neuro_config(bridge, env_config, options)
  end

  @doc """
  Get bridge info for debugging.
  """
  def info(bridge) do
    :agent_bridge.info(bridge)
  end

  @doc """
  Validate bridge configuration.
  """
  def validate(bridge) do
    :agent_bridge.validate(bridge)
  end

  @doc """
  Get network topology from the agent definition.
  """
  def topology do
    ForagerAgentDefinition.network_topology()
  end

  @doc """
  Create a random network matching the bridge topology.
  """
  def random_network do
    {inputs, hidden, outputs} = topology()
    :network_evaluator.create_feedforward(inputs, hidden, outputs, :tanh)
  end
end
