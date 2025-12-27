defmodule SwaiNode.Training.WorldEvaluator do
  @moduledoc """
  Domain-specific evaluator for 2D world simulation.

  Implements the `:neuroevolution_evaluator` behaviour from
  `macula_neuroevolution`. This module bridges the Elixir world
  simulation with the Erlang training infrastructure.

  ## Usage with macula_neuroevolution

  ```elixir
  config = %{
    population_size: 50,
    selection_ratio: 0.20,
    mutation_rate: 0.10,
    mutation_strength: 0.3,
    network_topology: {21, [28, 14], 6},
    evaluator_module: SwaiNode.Training.WorldEvaluator,
    evaluator_options: %{
      eval_ticks: 500,
      width: 800,
      height: 600
    }
  }

  {:ok, pid} = :neuroevolution_server.start_link(config)
  :neuroevolution_server.start_training(pid)
  ```

  ## Metrics

  The evaluator returns these metrics:
  - `:ticks_survived` - How many ticks the agent lived
  - `:food_eaten` - Number of food items consumed
  - `:kills` - Number of other agents killed (multi-agent mode)
  - `:final_energy` - Energy level at end of evaluation
  """

  @behaviour :neuroevolution_evaluator

  alias SwaiNode.Simulation.WorldSimulator

  # Default evaluation parameters
  @default_eval_ticks 500
  @default_width 800
  @default_height 600
  @default_max_food 150
  @default_food_spawn_rate 0.8

  @doc """
  Evaluate an individual by running it in the 2D world simulation.

  Takes an `#individual{}` record from neuroevolution.hrl and returns
  the same record with updated metrics field.

  ## Options

  - `:eval_ticks` - Number of ticks to run simulation (default: 500)
  - `:width` - World width (default: 800)
  - `:height` - World height (default: 600)
  - `:max_food` - Maximum food items (default: 150)
  - `:food_spawn_rate` - Food spawn probability per tick (default: 0.8)
  - `:notify_pid` - Optional PID for progress notifications
  """
  @impl :neuroevolution_evaluator
  def evaluate(individual, options) do
    # Extract network from Erlang record
    # #individual record indices:
    # 0 = record tag (:individual)
    # 1 = id
    # 2 = network
    # 3 = parent1_id
    # 4 = parent2_id
    # 5 = fitness
    # 6 = metrics
    # 7 = generation_born
    # 8 = is_survivor
    # 9 = is_offspring
    network = elem(individual, 2)

    # Get evaluation options
    eval_ticks = Map.get(options, :eval_ticks, @default_eval_ticks)
    notify_pid = Map.get(options, :notify_pid)

    sim_options = %{
      width: Map.get(options, :width, @default_width),
      height: Map.get(options, :height, @default_height),
      max_food: Map.get(options, :max_food, @default_max_food),
      food_spawn_rate: Map.get(options, :food_spawn_rate, @default_food_spawn_rate),
      other_agents: []
    }

    # Run simulation
    result = WorldSimulator.run_evaluation(network, eval_ticks, sim_options)

    # Notify if requested
    if notify_pid do
      send(notify_pid, {:evaluation_complete, result})
    end

    # Build metrics map
    metrics = %{
      ticks_survived: result.ticks,
      food_eaten: result.food_eaten,
      kills: result.kills,
      final_energy: result.energy
    }

    # Update metrics field (index 6 in the record)
    updated_individual = put_elem(individual, 6, metrics)

    {:ok, updated_individual}
  end

  @doc """
  Calculate fitness from evaluation metrics.

  Fitness formula rewards:
  - Survival (ticks lived) - base score
  - Food eaten - primary goal (50 points each)
  - Kills - predator bonus (100 points each)

  This formula encourages both foraging and hunting strategies
  while ensuring survival is still important.
  """
  @impl :neuroevolution_evaluator
  def calculate_fitness(metrics) do
    ticks = Map.get(metrics, :ticks_survived, 0)
    food = Map.get(metrics, :food_eaten, 0)
    kills = Map.get(metrics, :kills, 0)

    # Survival base: 1 point per tick
    survival_score = ticks * 1.0

    # Food bonus: 50 points per food eaten
    food_score = food * 50.0

    # Kill bonus: 100 points per kill
    kill_score = kills * 100.0

    survival_score + food_score + kill_score
  end
end
