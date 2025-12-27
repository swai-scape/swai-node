defmodule SwaiNode.Training.TrainingServer do
  @moduledoc """
  Training coordinator for neuroevolution.

  Wraps the Erlang `neuroevolution_server` and:
  - Configures it with our WorldEvaluator
  - Receives evolutionary events
  - Broadcasts events to Phoenix PubSub for dashboard visualization

  ## Usage

  ```elixir
  # Start training
  TrainingServer.start_training()

  # Check status
  TrainingServer.get_stats()

  # Get the best network for visualization
  TrainingServer.get_best_network()

  # Stop training
  TrainingServer.stop_training()
  ```

  ## Events Published

  Events are broadcast on the `training:events` PubSub topic:
  - `{:generation_complete, stats}` - Generation finished
  - `{:training_started, config}` - Training began
  - `{:training_complete, stats}` - Training finished
  - `{:champion_updated, individual}` - New best fitness achieved
  """

  use GenServer
  require Logger

  alias SwaiNode.Training.WorldEvaluator

  @pubsub SwaiNode.PubSub
  @topic "training:events"

  # Default training configuration
  @default_config %{
    population_size: 50,
    selection_ratio: 0.20,
    mutation_rate: 0.10,
    mutation_strength: 0.3,
    # Network: 37 inputs, 2 hidden layers, 6 outputs
    # Inputs: 24 vision (8 rays × 3 channels) + 4 hearing + 3 smell + 6 state = 37
    # Outputs: turn, move, eat, reproduce, signal, attack
    network_topology: {37, [48, 24], 6},
    max_generations: 10000,
    # Evaluator options
    eval_ticks: 500,
    width: 800,
    height: 600
  }

  # ==========================================================================
  # Client API
  # ==========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Start training (if not already running)"
  def start_training(server \\ __MODULE__) do
    GenServer.call(server, :start_training)
  end

  @doc "Stop training"
  def stop_training(server \\ __MODULE__) do
    GenServer.call(server, :stop_training)
  end

  @doc "Reset training (new population)"
  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

  @doc "Get current training stats"
  def get_stats(server \\ __MODULE__) do
    GenServer.call(server, :get_stats)
  end

  @doc "Get the best network from current population"
  def get_best_network(server \\ __MODULE__) do
    GenServer.call(server, :get_best_network)
  end

  @doc "Check if training is running"
  def running?(server \\ __MODULE__) do
    GenServer.call(server, :running?)
  end

  # ==========================================================================
  # Event Handler Callback (called by neuroevolution_server)
  # ==========================================================================

  @doc false
  def handle_event(event, pid) when is_pid(pid) do
    send(pid, {:neuro_event, event})
    pid
  end

  # ==========================================================================
  # GenServer Callbacks
  # ==========================================================================

  @impl true
  def init(opts) do
    config = Map.merge(@default_config, Map.new(opts))

    state = %{
      neuro_pid: nil,
      config: config,
      running: false,
      stats: %{
        generation: 0,
        best_fitness: 0.0,
        avg_fitness: 0.0,
        population: 0,
        total_evaluations: 0
      },
      best_network: nil,
      fitness_history: []
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:start_training, _from, %{running: true} = state) do
    {:reply, {:error, :already_running}, state}
  end

  @impl true
  def handle_call(:start_training, _from, state) do
    # Build neuroevolution config
    neuro_config = build_neuro_config(state.config)

    case :neuroevolution_server.start_link(neuro_config) do
      {:ok, pid} ->
        # Start training
        :neuroevolution_server.start_training(pid)

        Logger.info("[TrainingServer] Started neuroevolution training")
        broadcast({:training_started, state.config})

        new_state = %{state |
          neuro_pid: pid,
          running: true,
          stats: %{state.stats | generation: 0, best_fitness: 0.0},
          fitness_history: []
        }

        {:reply, :ok, new_state}

      {:error, reason} ->
        Logger.error("[TrainingServer] Failed to start: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:stop_training, _from, %{neuro_pid: nil} = state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:stop_training, _from, state) do
    if state.neuro_pid do
      :neuroevolution_server.stop_training(state.neuro_pid)
      GenServer.stop(state.neuro_pid, :normal)
    end

    broadcast({:training_stopped, state.stats})

    {:reply, :ok, %{state | neuro_pid: nil, running: false}}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    # Stop existing training
    if state.neuro_pid do
      GenServer.stop(state.neuro_pid, :normal)
    end

    new_state = %{state |
      neuro_pid: nil,
      running: false,
      stats: %{
        generation: 0,
        best_fitness: 0.0,
        avg_fitness: 0.0,
        population: 0,
        total_evaluations: 0
      },
      best_network: nil,
      fitness_history: []
    }

    broadcast({:training_reset, %{}})

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply, state.stats, state}
  end

  @impl true
  def handle_call(:get_best_network, _from, state) do
    {:reply, state.best_network, state}
  end

  @impl true
  def handle_call(:running?, _from, state) do
    {:reply, state.running, state}
  end

  # ==========================================================================
  # Event Handling
  # ==========================================================================

  @impl true
  def handle_info({:neuro_event, event}, state) do
    state = handle_neuro_event(event, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{neuro_pid: pid} = state) do
    Logger.warning("[TrainingServer] Neuroevolution server died: #{inspect(reason)}")
    {:noreply, %{state | neuro_pid: nil, running: false}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Handle generation_complete event
  defp handle_neuro_event({:generation_complete, data}, state) do
    gen_stats = Map.get(data, :generation_stats, %{})

    generation = Map.get(gen_stats, :generation, state.stats.generation)
    best_fitness = Map.get(gen_stats, :best_fitness, state.stats.best_fitness)
    avg_fitness = Map.get(gen_stats, :avg_fitness, state.stats.avg_fitness)
    population = Map.get(gen_stats, :population_size, state.stats.population)

    # Track champion
    champion = Map.get(gen_stats, :champion)
    best_network = extract_network(champion) || state.best_network

    # Update stats
    stats = %{
      generation: generation,
      best_fitness: best_fitness,
      avg_fitness: avg_fitness,
      population: population,
      total_evaluations: generation * population
    }

    # Track fitness history (last 100 points)
    point = %{generation: generation, best: best_fitness, avg: avg_fitness}
    history = [point | state.fitness_history] |> Enum.take(100)

    # Broadcast to dashboard
    broadcast({:generation_complete, stats})

    %{state |
      stats: stats,
      best_network: best_network,
      fitness_history: history
    }
  end

  # Handle training_complete event
  defp handle_neuro_event({:training_complete, data}, state) do
    Logger.info("[TrainingServer] Training complete: #{inspect(data)}")
    broadcast({:training_complete, data})
    %{state | running: false}
  end

  # Handle other events
  defp handle_neuro_event({event_type, data}, state) do
    # Log but don't broadcast less important events
    Logger.debug("[TrainingServer] Event: #{event_type}")
    broadcast({event_type, data})
    state
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp build_neuro_config(config) do
    # Build evaluator options
    evaluator_options = %{
      eval_ticks: config.eval_ticks,
      width: config.width,
      height: config.height,
      max_food: Map.get(config, :max_food, 150),
      food_spawn_rate: Map.get(config, :food_spawn_rate, 0.8)
    }

    # Build the config map for neuroevolution
    neuro_map = %{
      population_size: config.population_size,
      selection_ratio: config.selection_ratio,
      mutation_rate: config.mutation_rate,
      mutation_strength: config.mutation_strength,
      network_topology: config.network_topology,
      max_generations: config.max_generations,
      evaluator_module: WorldEvaluator,
      evaluator_options: evaluator_options,
      event_handler: {__MODULE__, self()},
      # Use steady-state selection for continuous evolution
      selection_strategy: :steady_state,
      # Don't auto-stop on fitness threshold
      fitness_threshold: :infinity
    }

    :neuro_config.from_map(neuro_map)
  end

  defp extract_network(nil), do: nil
  defp extract_network(individual) when is_tuple(individual) do
    # Network is at index 2 in the individual record
    elem(individual, 2)
  end

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, event)
  end
end
