defmodule SwaiNode.Training.HexWorldEvaluator do
  @moduledoc """
  Hex-based evaluator for neuroevolution training.

  Runs isolated hex world simulations to evaluate neural networks.
  Uses the same hex movement, vision, and eating logic as HexWorldServer.

  Implements the `:neuroevolution_evaluator` behaviour.

  ## Domain

  Uses `SwaiNode.Domain.HexArena` for:
  - Network topology (29 inputs, [32,16] hidden, 9 outputs)
  - Environment parameters (arena radius, walls, food)
  - Reward function (survival + food + kills)
  """

  @behaviour :neuroevolution_evaluator
  require Logger

  alias SwaiNode.Simulation.{Hex, HexMaze, HexVision, AgentBrain}
  alias SwaiNode.Domain.HexArena

  # Evaluation arena is smaller than display arena for faster learning
  @arena_radius 15  # Smaller arena = denser food = faster learning
  @wall_percent 8   # Fewer walls = easier navigation
  @open_center_radius 3
  @max_food 60      # Keep food density high
  @food_spawn_rate 0.9  # Spawn food more often
  @starting_energy HexArena.starting_energy()
  @max_energy HexArena.max_energy()
  @move_cost HexArena.move_cost()
  @eat_gain HexArena.eat_gain()

  # Default evaluation
  @default_eval_ticks 500

  @impl :neuroevolution_evaluator
  def evaluate(individual, options) do
    network = elem(individual, 2)
    eval_ticks = Map.get(options, :eval_ticks, @default_eval_ticks)

    # Run isolated hex simulation
    result = run_hex_simulation(network, eval_ticks)

    # Calculate fitness directly
    survival_score = result.ticks * 0.1      # Reduced from 0.5 to discourage passive survival
    food_score = result.food_eaten * 150.0   # 150 points per food - eating is the goal!
    kill_score = result.kills * 100.0        # 100 points per kill
    approach_score = result.approach_bonus   # Bonus for moving toward food
    fitness = survival_score + food_score + kill_score + approach_score

    # Build metrics
    metrics = %{
      ticks_survived: result.ticks,
      food_eaten: result.food_eaten,
      kills: result.kills,
      final_energy: result.energy,
      approach_bonus: result.approach_bonus
    }

    # Debug: log occasionally
    if :rand.uniform(500) == 1 do
      Logger.debug("[HexWorldEvaluator] Result: ticks=#{result.ticks}, food=#{result.food_eaten}, approach=#{Float.round(approach_score, 1)}, fitness=#{Float.round(fitness, 1)}")
    end

    # Update individual record (Erlang record #individual{}):
    # - Index 6: fitness field
    # - Index 7: metrics field
    updated_individual =
      individual
      |> put_elem(6, fitness)
      |> put_elem(7, metrics)

    {:ok, updated_individual}
  end

  @impl :neuroevolution_evaluator
  def calculate_fitness(metrics) when is_map(metrics) do
    # Delegate to domain definition
    fitness = HexArena.calculate_fitness(metrics)

    # Debug: log occasionally
    if :rand.uniform(1000) == 1 do
      ticks = Map.get(metrics, :ticks_survived, 0)
      food = Map.get(metrics, :food_eaten, 0)
      kills = Map.get(metrics, :kills, 0)
      Logger.debug("[HexWorldEvaluator] Fitness: #{fitness} (ticks=#{ticks}, food=#{food}, kills=#{kills})")
    end

    fitness
  end

  # Handle case where metrics might come as something else
  def calculate_fitness(other) do
    Logger.warning("[HexWorldEvaluator] calculate_fitness received non-map: #{inspect(other)}")
    0.0
  end

  # Run isolated simulation for one network
  defp run_hex_simulation(network, max_ticks) do
    # Generate walls
    walls = HexMaze.generate_scatter(@arena_radius,
      wall_percent: @wall_percent,
      open_center_radius: @open_center_radius
    )

    # Spawn agent at center
    agent = %{
      hex: {0, 0},
      energy: @starting_energy,
      age: 0,
      signal: 0.5,
      generation: 0,
      food_eaten: 0,
      kills: 0,
      network: network
    }

    # Initial food - spawn more for denser gradient signal
    food = spawn_initial_food(walls, 40)

    # Track initial distance to nearest food for proximity bonus
    initial_food_dist = nearest_food_distance(agent.hex, food)

    # Run simulation loop with approach tracking
    run_loop(agent, food, walls, 0, max_ticks, initial_food_dist, 0.0)
  end

  defp run_loop(agent, _food, _walls, tick, max_ticks, _prev_dist, approach_bonus) when tick >= max_ticks do
    %{
      ticks: tick,
      food_eaten: agent.food_eaten,
      kills: agent.kills,
      energy: agent.energy,
      approach_bonus: approach_bonus
    }
  end

  defp run_loop(agent, _food, _walls, tick, _max_ticks, _prev_dist, approach_bonus) when agent.energy <= 0 do
    %{
      ticks: tick,
      food_eaten: agent.food_eaten,
      kills: agent.kills,
      energy: 0.0,
      approach_bonus: approach_bonus
    }
  end

  defp run_loop(agent, food, walls, tick, max_ticks, prev_dist, approach_bonus) do
    # Calculate vision (6 rays × 3 channels = 18 values)
    vision = HexVision.cast_rays(agent.hex, [], food, walls, @arena_radius)

    # Hearing/smell are simplified (no other agents in single-agent eval)
    hearing = [0.0, 0.0, 0.0, 0.0]
    smell = [min(map_size(food) / 10, 1.0), 0.0, 0.0]

    # Build inputs and evaluate
    inputs = AgentBrain.build_hex_inputs(agent, vision, hearing, smell)
    outputs = AgentBrain.evaluate(agent.network, inputs)
    actions = AgentBrain.parse_hex_outputs(outputs)

    # Apply movement
    new_hex = apply_movement(agent.hex, actions, walls)

    # Check for eating
    {agent, food} = check_eating(agent, new_hex, food)

    # Update agent
    agent = %{agent |
      hex: new_hex,
      energy: agent.energy - @move_cost,
      age: agent.age + 1,
      signal: actions.signal
    }

    # Maybe spawn food
    food = maybe_spawn_food(food, walls)

    # Calculate approach bonus: reward getting closer to food
    new_dist = nearest_food_distance(new_hex, food)
    # Strong bonus for getting closer - 5 points per hex closer
    # This creates a gradient toward food even before eating
    delta_bonus = if new_dist < prev_dist, do: (prev_dist - new_dist) * 5.0, else: 0.0
    # Small penalty for moving away to discourage random wandering
    delta_penalty = if new_dist > prev_dist, do: (new_dist - prev_dist) * 1.0, else: 0.0
    new_approach_bonus = approach_bonus + delta_bonus - delta_penalty

    run_loop(agent, food, walls, tick + 1, max_ticks, new_dist, new_approach_bonus)
  end

  # Stay penalty to match Actuator behavior - encourages movement
  @stay_penalty 0.20

  defp apply_movement(hex, actions, walls) do
    # Get direction preferences [E, NE, NW, W, SW, SE, STAY]
    direction_prefs = actions.directions

    # Apply stay penalty to encourage movement (same as Actuator)
    adjusted_prefs =
      direction_prefs
      |> Enum.with_index()
      |> Enum.map(fn {pref, idx} ->
        if idx == 6, do: max(0.0, pref - @stay_penalty), else: pref
      end)

    # Find best valid direction
    {_pref, best_dir} =
      adjusted_prefs
      |> Enum.with_index()
      |> Enum.filter(fn {_pref, dir} ->
        if dir == 6 do
          true  # Stay is always valid
        else
          target = Hex.neighbor(hex, dir)
          Hex.in_bounds?(target, @arena_radius) and
            not MapSet.member?(walls, target)
        end
      end)
      |> Enum.max_by(fn {pref, _} -> pref end, fn -> {0.0, 6} end)

    if best_dir == 6 do
      hex
    else
      Hex.neighbor(hex, best_dir)
    end
  end

  defp check_eating(agent, hex, food) do
    case Map.get(food, hex) do
      nil ->
        {agent, food}

      _food_data ->
        updated = %{agent |
          energy: min(agent.energy + @eat_gain, @max_energy),
          food_eaten: agent.food_eaten + 1
        }
        {updated, Map.delete(food, hex)}
    end
  end

  defp spawn_initial_food(walls, count) do
    Enum.reduce(1..count, %{}, fn _, acc ->
      case Hex.random_open_hex(@arena_radius, walls) do
        nil -> acc
        hex -> Map.put(acc, hex, %{energy: 20.0})
      end
    end)
  end

  defp maybe_spawn_food(food, walls) do
    if map_size(food) < @max_food and :rand.uniform() < @food_spawn_rate do
      case Hex.random_open_hex(@arena_radius, walls) do
        nil -> food
        hex -> Map.put(food, hex, %{energy: 20.0})
      end
    else
      food
    end
  end

  # Calculate distance to nearest food item
  defp nearest_food_distance(_hex, food) when map_size(food) == 0, do: @arena_radius * 2
  defp nearest_food_distance(hex, food) do
    food
    |> Map.keys()
    |> Enum.map(&Hex.distance(hex, &1))
    |> Enum.min()
  end
end
