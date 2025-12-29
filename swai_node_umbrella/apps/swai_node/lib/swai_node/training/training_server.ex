defmodule SwaiNode.Training.TrainingServer do
  @moduledoc """
  Training coordinator for neuroevolution.

  This is a thin coordinator that:
  - Configures and manages the neuroevolution_server lifecycle
  - Publishes events to PubSub for projections and visualizations
  - Provides the neuro_pid for live population queries

  ## Responsibilities

  1. Start/stop/reset training
  2. Configure evaluator and LC silos
  3. Publish events (projections subscribe independently)
  4. Expose neuro_pid for live queries

  ## Events Published

  Events are broadcast on the `training:events` PubSub topic:
  - `{:training_started, config}` - Training began
  - `{:training_stopped, stats}` - Training stopped
  - `{:training_reset, %{}}` - Training reset
  - `{:generation_complete, stats}` - Generation finished
  - `{:training_complete, data}` - Max generations reached
  - `{:champion_updated, individual}` - New best fitness

  ## Usage

      TrainingServer.start_training()
      TrainingServer.stop_training()
      TrainingServer.reset()
      TrainingServer.running?()
      TrainingServer.get_neuro_pid()
  """

  use GenServer
  require Logger

  alias SwaiNode.Training.HexWorldEvaluator
  alias SwaiNode.Domain.HexArena

  @pubsub SwaiNode.PubSub
  @topic "training:events"

  # Default training configuration
  @default_config %{
    population_size: 30,
    selection_ratio: 0.20,
    mutation_rate: 0.10,
    mutation_strength: 0.3,
    network_topology: HexArena.network_topology(),
    max_generations: 10000,
    eval_ticks: 200,
    arena_radius: HexArena.default_arena_radius()
  }

  # ===========================================================================
  # Client API
  # ===========================================================================

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

  @doc "Check if training is running"
  def running?(server \\ __MODULE__) do
    GenServer.call(server, :running?)
  end

  @doc "Get the neuroevolution server PID for live queries"
  def get_neuro_pid(server \\ __MODULE__) do
    GenServer.call(server, :get_neuro_pid)
  end

  @doc "Get current training config"
  def get_config(server \\ __MODULE__) do
    GenServer.call(server, :get_config)
  end

  # Legacy API - delegates to ChampionArchive projection
  @doc "Get the best network (delegates to ChampionArchive)"
  def get_best_network(server \\ __MODULE__) do
    pid = GenServer.call(server, :get_neuro_pid)
    get_best_network_from_server(pid)
  end

  # Legacy API - returns basic stats from last event
  @doc "Get current stats (basic - use projections for full history)"
  def get_stats(server \\ __MODULE__) do
    GenServer.call(server, :get_stats)
  end

  # ===========================================================================
  # Event Handler Callback (called by neuroevolution_server)
  # ===========================================================================

  @doc false
  def handle_event(event, pid) when is_pid(pid) do
    send(pid, {:neuro_event, event})
    pid
  end

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl true
  def init(opts) do
    config = Map.merge(@default_config, Map.new(opts))

    state = %{
      neuro_pid: nil,
      config: config,
      running: false,
      last_stats: %{generation: 0, best_fitness: 0.0, avg_fitness: 0.0, population: 0}
    }

    # Auto-start training
    send(self(), :auto_start_training)

    {:ok, state}
  end

  @impl true
  def handle_info(:auto_start_training, %{running: false} = state) do
    Logger.info("[TrainingServer] Auto-starting training...")
    do_start_training(state)
  end

  def handle_info(:auto_start_training, state), do: {:noreply, state}

  @impl true
  def handle_info({:neuro_event, event}, state) do
    state = handle_neuro_event(event, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{neuro_pid: pid} = state) do
    Logger.warning("[TrainingServer] Neuroevolution server died: #{inspect(reason)}")
    broadcast({:training_stopped, state.last_stats})
    {:noreply, %{state | neuro_pid: nil, running: false}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:start_training, _from, %{running: true} = state) do
    {:reply, {:error, :already_running}, state}
  end

  def handle_call(:start_training, _from, state) do
    case do_start_training(state) do
      {:noreply, new_state} -> {:reply, :ok, new_state}
      other -> other
    end
  end

  @impl true
  def handle_call(:stop_training, _from, %{neuro_pid: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:stop_training, _from, state) do
    if state.neuro_pid do
      :neuroevolution_server.stop_training(state.neuro_pid)
      GenServer.stop(state.neuro_pid, :normal)
    end
    broadcast({:training_stopped, state.last_stats})
    {:reply, :ok, %{state | neuro_pid: nil, running: false}}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    if state.neuro_pid, do: GenServer.stop(state.neuro_pid, :normal)
    broadcast({:training_reset, %{}})
    {:reply, :ok, %{state | neuro_pid: nil, running: false, last_stats: %{generation: 0, best_fitness: 0.0, avg_fitness: 0.0, population: 0}}}
  end

  @impl true
  def handle_call(:running?, _from, state), do: {:reply, state.running, state}

  @impl true
  def handle_call(:get_neuro_pid, _from, state), do: {:reply, state.neuro_pid, state}

  @impl true
  def handle_call(:get_config, _from, state), do: {:reply, state.config, state}

  @impl true
  def handle_call(:get_stats, _from, state), do: {:reply, state.last_stats, state}

  # ===========================================================================
  # Private - Training Lifecycle
  # ===========================================================================

  defp do_start_training(state) do
    neuro_config = build_neuro_config(state.config)

    case :neuroevolution_server.start_link(neuro_config) do
      {:ok, pid} ->
        Process.monitor(pid)
        :neuroevolution_server.start_training(pid)
        Logger.info("[TrainingServer] Training started")
        broadcast({:training_started, state.config})
        {:noreply, %{state | neuro_pid: pid, running: true}}

      {:error, reason} ->
        Logger.error("[TrainingServer] Failed to start: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  defp build_neuro_config(config) do
    neuro_map = %{
      population_size: config.population_size,
      selection_ratio: config.selection_ratio,
      mutation_rate: config.mutation_rate,
      mutation_strength: config.mutation_strength,
      network_topology: config.network_topology,
      max_generations: config.max_generations,
      evaluator_module: HexWorldEvaluator,
      evaluator_options: %{
        eval_ticks: config.eval_ticks,
        arena_radius: config.arena_radius
      },
      event_handler: {__MODULE__, self()},
      selection_strategy: :steady_state,
      fitness_threshold: :infinity
    }

    :neuro_config.from_map(neuro_map)
  end

  # ===========================================================================
  # Private - Event Handling
  # ===========================================================================

  defp handle_neuro_event({:generation_complete, data}, state) do
    gen_stats = Map.get(data, :generation_stats, %{})
    stats = extract_stats(gen_stats, state.last_stats)

    # Broadcast for projections
    broadcast({:generation_complete, stats})

    %{state | last_stats: stats}
  end

  defp handle_neuro_event({:training_complete, data}, state) do
    Logger.info("[TrainingServer] Training complete")
    broadcast({:training_complete, data})
    %{state | running: false}
  end

  defp handle_neuro_event({event_type, data}, state) do
    Logger.debug("[TrainingServer] Event: #{event_type}")
    broadcast({event_type, data})
    state
  end

  defp extract_stats(gen_stats, defaults) when is_tuple(gen_stats) and tuple_size(gen_stats) >= 10 do
    %{
      generation: safe_num(elem(gen_stats, 1), defaults.generation),
      best_fitness: safe_num(elem(gen_stats, 2), defaults.best_fitness),
      avg_fitness: safe_num(elem(gen_stats, 3), defaults.avg_fitness),
      population: safe_num(elem(gen_stats, 9), defaults.population)
    }
  end

  defp extract_stats(gen_stats, defaults) when is_map(gen_stats) do
    %{
      generation: Map.get(gen_stats, :generation, defaults.generation),
      best_fitness: Map.get(gen_stats, :best_fitness, defaults.best_fitness),
      avg_fitness: Map.get(gen_stats, :avg_fitness, defaults.avg_fitness),
      population: Map.get(gen_stats, :population_size, defaults.population)
    }
  end

  defp extract_stats(_, defaults), do: defaults

  defp safe_num(val, _) when is_number(val), do: val
  defp safe_num(:undefined, default), do: default
  defp safe_num(_, default), do: default

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, event)
  end

  # ===========================================================================
  # Private - Live Population Query
  # ===========================================================================

  defp get_best_network_from_server(nil), do: nil
  defp get_best_network_from_server(pid) do
    try do
      case :neuroevolution_server.get_population(pid) do
        {:ok, population} when is_list(population) and length(population) > 0 ->
          best = Enum.max_by(population, fn ind ->
            case ind do
              tuple when is_tuple(tuple) and tuple_size(tuple) >= 7 ->
                case elem(tuple, 6) do
                  f when is_number(f) -> f
                  _ -> 0.0
                end
              _ -> 0.0
            end
          end)

          case best do
            tuple when is_tuple(tuple) and tuple_size(tuple) >= 3 -> elem(tuple, 2)
            _ -> nil
          end
        _ -> nil
      end
    catch
      :exit, _ -> nil
    end
  end
end
