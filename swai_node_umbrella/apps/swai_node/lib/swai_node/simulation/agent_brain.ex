defmodule SwaiNode.Simulation.AgentBrain do
  @moduledoc """
  Neural network wrapper for agent brains.

  Uses macula_tweann's network_evaluator for fast synchronous evaluation.

  Network Architecture:
  - Inputs (37):
    - 24 vision rays (8 rays × 3 channels: food, agent, wall)
    - 4 hearing channels (signals from 4 nearest agents, 0 if none)
    - 3 smell channels (food density, prey density, threat density)
    - Energy level (normalized 0-1)
    - Age (normalized 0-1)
    - Direction (sin, cos) = 2
    - Own signal (what I'm broadcasting)
    - Generation (normalized 0-1)
  - Hidden: [48, 24] neurons with tanh activation
  - Outputs (6):
    - Turn (-1 to 1): how much to rotate
    - Move (0 to 1): forward movement speed
    - Eat (0 to 1): threshold for eating action (unused - eating is automatic)
    - Reproduce (0 to 1): threshold for reproduction (unused - automatic)
    - Signal (0 to 1): broadcast value for communication
    - Attack (0 to 1): threshold for attacking nearby agents
  """

  @input_size 37
  @hidden_layers [48, 24]
  @output_size 6
  @activation :tanh

  # Hex arena constants
  @hex_input_size 29   # 18 vision + 4 hearing + 3 smell + 4 state
  @hex_hidden_layers [32, 16]
  @hex_output_size 9   # 6 directions + stay + signal + attack
  @hex_vision_channels 18  # 6 rays × 3 types

  @max_age 10000
  @max_energy 200.0
  @max_generation 100  # For normalization
  @hearing_channels 4  # Listen to 4 nearest agents
  @smell_channels 3    # Food, prey, threat densities
  @vision_channels 24  # 8 rays × 3 types (food, agent, wall)

  @doc """
  Create a new random neural network for an agent.
  """
  @spec create_network() :: term()
  def create_network do
    :network_evaluator.create_feedforward(@input_size, @hidden_layers, @output_size, @activation)
  end

  @doc """
  Evaluate the network with the given inputs.

  Returns a list of outputs matching the network architecture.
  """
  @spec evaluate(term(), list(float())) :: list(float())
  def evaluate(network, inputs) when length(inputs) == @input_size do
    :network_evaluator.evaluate(network, inputs)
  end

  def evaluate(network, inputs) when length(inputs) == @hex_input_size do
    :network_evaluator.evaluate(network, inputs)
  end

  @doc """
  Build input vector from agent state, vision data, hearing data, and smell data.

  Vision data: list of 24 floats (0-1) - 8 rays × 3 channels (food, agent, wall).
  Hearing data: list of 4 floats (0-1) - signals from 4 nearest agents.
  Smell data: list of 3 floats (0-1) - [food_density, prey_density, threat_density]
  """
  @spec build_inputs(map(), list(float()), list(float()), list(float())) :: list(float())
  def build_inputs(agent_state, vision_data, hearing_data \\ [0.0, 0.0, 0.0, 0.0], smell_data \\ [0.0, 0.0, 0.0])

  def build_inputs(agent_state, vision_data, hearing_data, smell_data)
      when length(vision_data) == @vision_channels and length(hearing_data) == @hearing_channels and length(smell_data) == @smell_channels do
    %{energy: energy, age: age, direction: direction, signal: signal, generation: generation} = agent_state

    # Normalize inputs to 0-1 range
    normalized_energy = min(energy / @max_energy, 1.0)
    normalized_age = min(age / @max_age, 1.0)
    direction_sin = :math.sin(direction)
    direction_cos = :math.cos(direction)
    normalized_signal = signal || 0.0
    normalized_generation = min(generation / @max_generation, 1.0)

    # Combine: vision (24) + hearing (4) + smell (3) + energy (1) + age (1) + direction (2) + signal (1) + generation (1) = 37
    vision_data ++ hearing_data ++ smell_data ++ [
      normalized_energy,
      normalized_age,
      direction_sin,
      direction_cos,
      normalized_signal,
      normalized_generation
    ]
  end

  # Fallback for agents without signal field (backwards compatibility)
  def build_inputs(agent_state, vision_data, hearing_data, smell_data) when length(vision_data) == @vision_channels do
    agent_with_signal = Map.merge(%{signal: 0.0, generation: 0}, agent_state)
    build_inputs(agent_with_signal, vision_data, hearing_data, smell_data)
  end

  # Legacy fallback for old 8-channel vision (backwards compatibility)
  def build_inputs(agent_state, vision_data, hearing_data, smell_data) when length(vision_data) == 8 do
    # Expand 8-channel vision to 24-channel by duplicating (food = agent = wall)
    expanded_vision = vision_data ++ vision_data ++ vision_data
    agent_with_signal = Map.merge(%{signal: 0.0, generation: 0}, agent_state)
    build_inputs(agent_with_signal, expanded_vision, hearing_data, smell_data)
  end

  @doc """
  Parse network outputs into actions.

  Returns a map with action values including signal and attack.
  """
  @spec parse_outputs(list(float())) :: map()
  def parse_outputs([turn, move, eat, reproduce, signal, attack]) do
    %{
      turn: turn,
      move: (move + 1.0) / 2.0,  # Map -1..1 to 0..1 - always some movement
      eat: eat > 0.5,
      reproduce: reproduce > 0.5,
      signal: (signal + 1.0) / 2.0,  # Convert from -1..1 to 0..1
      attack: attack > 0.7  # High threshold - must "really want" to attack
    }
  end

  def parse_outputs(outputs) when length(outputs) == @output_size do
    [turn, move, eat, reproduce, signal, attack] = outputs
    parse_outputs([turn, move, eat, reproduce, signal, attack])
  end

  # Backwards compatibility for old 5-output networks (no attack)
  def parse_outputs([turn, move, eat, reproduce, signal]) do
    %{
      turn: turn,
      move: (move + 1.0) / 2.0,
      eat: eat > 0.5,
      reproduce: reproduce > 0.5,
      signal: (signal + 1.0) / 2.0,
      attack: false
    }
  end

  # Backwards compatibility for old 4-output networks
  def parse_outputs([turn, move, eat, reproduce]) do
    %{
      turn: turn,
      move: (move + 1.0) / 2.0,
      eat: eat > 0.5,
      reproduce: reproduce > 0.5,
      signal: 0.5,
      attack: false
    }
  end

  @doc """
  Get the number of hearing channels.
  """
  def hearing_channels, do: @hearing_channels

  @doc """
  Get the number of smell channels.
  """
  def smell_channels, do: @smell_channels

  @doc """
  Serialize network to binary for storage.
  """
  @spec serialize(term()) :: binary()
  def serialize(network) do
    :network_evaluator.to_binary(network)
  end

  @doc """
  Deserialize network from binary.
  """
  @spec deserialize(binary()) :: term()
  def deserialize(binary) do
    :network_evaluator.from_binary(binary)
  end

  @doc """
  Get the weights from a network as a flat list.
  """
  @spec get_weights(term()) :: list(float())
  def get_weights(network) do
    :network_evaluator.get_weights(network)
  end

  @doc """
  Set weights on a network from a flat list.
  """
  @spec set_weights(term(), list(float())) :: term()
  def set_weights(network, weights) do
    :network_evaluator.set_weights(network, weights)
  end

  @doc """
  Clone a network (create a copy with same weights).
  """
  @spec clone(term()) :: term()
  def clone(network) do
    weights = get_weights(network)
    new_network = create_network()
    set_weights(new_network, weights)
  end

  @doc """
  Mutate a network's weights with Gaussian noise.
  """
  @spec mutate(term(), float(), float()) :: term()
  def mutate(network, mutation_rate \\ 0.1, mutation_strength \\ 0.3) do
    weights = get_weights(network)

    mutated_weights =
      Enum.map(weights, fn weight ->
        if :rand.uniform() < mutation_rate do
          weight + :rand.normal() * mutation_strength
        else
          weight
        end
      end)

    set_weights(network, mutated_weights)
  end

  @doc """
  Create offspring network from parent (clone + mutate).
  """
  @spec create_offspring(term(), float(), float()) :: term()
  def create_offspring(parent_network, mutation_rate \\ 0.1, mutation_strength \\ 0.3) do
    parent_network
    |> clone()
    |> mutate(mutation_rate, mutation_strength)
  end

  # ===========================================================================
  # Hex Arena Functions
  # ===========================================================================

  @doc """
  Create a new neural network for hex arena agents.

  Network architecture:
  - Inputs (29): 18 vision + 4 hearing + 3 smell + 4 state
  - Hidden: [32, 16] neurons
  - Outputs (9): 6 directions + stay + signal + attack
  """
  @spec create_hex_network() :: term()
  def create_hex_network do
    :network_evaluator.create_feedforward(@hex_input_size, @hex_hidden_layers, @hex_output_size, @activation)
  end

  @doc """
  Build input vector for hex arena agents.

  Vision data: list of 18 floats - 6 rays × 3 channels (food, agent, wall)
  Hearing data: list of 4 floats - signals from 4 nearest agents
  Smell data: list of 3 floats - [food_density, prey_density, threat_density]
  """
  @spec build_hex_inputs(map(), list(float()), list(float()), list(float())) :: list(float())
  def build_hex_inputs(agent_state, vision_data, hearing_data \\ [0.0, 0.0, 0.0, 0.0], smell_data \\ [0.0, 0.0, 0.0])

  def build_hex_inputs(agent_state, vision_data, hearing_data, smell_data)
      when length(vision_data) == @hex_vision_channels and
           length(hearing_data) == @hearing_channels and
           length(smell_data) == @smell_channels do
    %{energy: energy, age: age, signal: signal, generation: generation} = agent_state

    # Normalize inputs to 0-1 range
    normalized_energy = min(energy / @max_energy, 1.0)
    normalized_age = min(age / @max_age, 1.0)
    normalized_signal = signal || 0.0
    normalized_generation = min(generation / @max_generation, 1.0)

    # Combine: vision (18) + hearing (4) + smell (3) + energy (1) + age (1) + signal (1) + generation (1) = 29
    vision_data ++ hearing_data ++ smell_data ++ [
      normalized_energy,
      normalized_age,
      normalized_signal,
      normalized_generation
    ]
  end

  # Fallback with default signal
  def build_hex_inputs(agent_state, vision_data, hearing_data, smell_data) when length(vision_data) == @hex_vision_channels do
    agent_with_defaults = Map.merge(%{signal: 0.0, generation: 0, age: 0, energy: 100.0}, agent_state)
    build_hex_inputs(agent_with_defaults, vision_data, hearing_data, smell_data)
  end

  @doc """
  Parse hex network outputs into actions.

  Outputs: [E, NE, NW, W, SW, SE, STAY, signal, attack]
  Returns map with direction preferences and actions.
  """
  @spec parse_hex_outputs(list(float())) :: map()
  def parse_hex_outputs(outputs) when length(outputs) == @hex_output_size do
    [e, ne, nw, w, sw, se, stay, signal, attack] = outputs

    # Apply softmax to direction outputs for probability distribution
    direction_raw = [e, ne, nw, w, sw, se, stay]
    directions = softmax(direction_raw)

    %{
      directions: directions,  # List of 7 normalized preferences
      signal: (signal + 1.0) / 2.0,  # Convert from -1..1 to 0..1
      attack: attack > 0.7  # High threshold for attack
    }
  end

  @doc """
  Clone a hex network (create a copy with same weights).
  """
  @spec clone_hex_network(term()) :: term()
  def clone_hex_network(network) do
    weights = get_weights(network)
    new_network = create_hex_network()
    set_weights(new_network, weights)
  end

  @doc """
  Create offspring network from hex parent (clone + mutate).
  """
  @spec create_hex_offspring(term(), float(), float()) :: term()
  def create_hex_offspring(parent_network, mutation_rate \\ 0.1, mutation_strength \\ 0.3) do
    parent_network
    |> clone_hex_network()
    |> mutate(mutation_rate, mutation_strength)
  end

  # Softmax function for direction selection
  defp softmax(values) do
    # Subtract max for numerical stability
    max_val = Enum.max(values)
    exp_values = Enum.map(values, fn v -> :math.exp(v - max_val) end)
    sum_exp = Enum.sum(exp_values)
    Enum.map(exp_values, fn v -> v / sum_exp end)
  end
end
