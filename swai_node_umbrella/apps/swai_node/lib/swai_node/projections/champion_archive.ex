defmodule SwaiNode.Projections.ChampionArchive do
  @moduledoc """
  Projection that archives champion networks from neuroevolution training.

  Maintains a collection of the best-performing networks, allowing:
  - Retrieval of the current best network for visualization
  - Historical champions for analysis
  - Network persistence across training sessions

  ## Read Model

  Archives champions with their:
  - Neural network structure
  - Fitness score
  - Generation discovered
  - Evaluation metrics

  ## Usage

      # Get the current best network
      ChampionArchive.get_best_network()

      # Get champion at specific generation
      ChampionArchive.get_champion(generation: 100)

      # Get all archived champions
      ChampionArchive.list_champions()
  """

  use GenServer
  require Logger

  @pubsub SwaiNode.PubSub
  @topic "training:events"
  @max_archive 100

  # ===========================================================================
  # Client API
  # ===========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get the current best network"
  def get_best_network do
    GenServer.call(__MODULE__, :get_best_network)
  end

  @doc "Get champion info at specific generation"
  def get_champion(opts \\ []) do
    GenServer.call(__MODULE__, {:get_champion, opts})
  end

  @doc "List all archived champions"
  def list_champions do
    GenServer.call(__MODULE__, :list_champions)
  end

  @doc "Get the current best fitness"
  def get_best_fitness do
    GenServer.call(__MODULE__, :get_best_fitness)
  end

  @doc "Clear archive (e.g., on training reset)"
  def clear do
    GenServer.cast(__MODULE__, :clear)
  end

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(@pubsub, @topic)

    state = %{
      current_best: nil,
      current_fitness: 0.0,
      archive: [],
      neuro_pid: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_best_network, _from, state) do
    # Try live population first, fall back to archived
    network = get_live_best_network(state.neuro_pid) || extract_network(state.current_best)
    {:reply, network, state}
  end

  @impl true
  def handle_call(:get_best_fitness, _from, state) do
    {:reply, state.current_fitness, state}
  end

  @impl true
  def handle_call({:get_champion, opts}, _from, state) do
    generation = Keyword.get(opts, :generation)

    champion =
      if generation do
        Enum.find(state.archive, fn c -> c.generation == generation end)
      else
        List.first(state.archive)
      end

    {:reply, champion, state}
  end

  @impl true
  def handle_call(:list_champions, _from, state) do
    {:reply, state.archive, state}
  end

  @impl true
  def handle_cast(:clear, _state) do
    {:noreply, %{
      current_best: nil,
      current_fitness: 0.0,
      archive: [],
      neuro_pid: nil
    }}
  end

  # ===========================================================================
  # Event Handlers
  # ===========================================================================

  @impl true
  def handle_info({:training_started, _config}, state) do
    # Could capture neuro_pid here if passed in event
    {:noreply, state}
  end

  @impl true
  def handle_info({:generation_complete, stats}, state) do
    # Archive if this is a new peak
    new_state =
      if stats.best_fitness > state.current_fitness do
        champion_entry = %{
          generation: stats.generation,
          fitness: stats.best_fitness,
          avg_fitness: stats.avg_fitness,
          timestamp: System.system_time(:millisecond)
        }

        archive = [champion_entry | state.archive] |> Enum.take(@max_archive)

        %{state |
          current_fitness: stats.best_fitness,
          archive: archive
        }
      else
        state
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:champion_updated, individual}, state) do
    # Direct champion update from neuroevolution
    network = extract_network(individual)
    fitness = extract_fitness(individual)

    new_state =
      if fitness > state.current_fitness do
        %{state |
          current_best: individual,
          current_fitness: fitness
        }
      else
        state
      end

    if network do
      Logger.debug("[ChampionArchive] New champion: fitness=#{fitness}")
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:training_reset, _}, _state) do
    {:noreply, %{
      current_best: nil,
      current_fitness: 0.0,
      archive: [],
      neuro_pid: nil
    }}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp get_live_best_network(nil), do: nil
  defp get_live_best_network(pid) do
    try do
      case :neuroevolution_server.get_population(pid) do
        {:ok, population} when is_list(population) and length(population) > 0 ->
          best = Enum.max_by(population, &extract_fitness/1, fn -> nil end)
          extract_network(best)
        _ ->
          nil
      end
    catch
      :exit, _ -> nil
    end
  end

  defp extract_network(nil), do: nil
  defp extract_network(:undefined), do: nil
  defp extract_network(individual) when is_tuple(individual) and tuple_size(individual) >= 3 do
    elem(individual, 2)
  end
  defp extract_network(_), do: nil

  defp extract_fitness(nil), do: 0.0
  defp extract_fitness(:undefined), do: 0.0
  defp extract_fitness(individual) when is_tuple(individual) and tuple_size(individual) >= 7 do
    case elem(individual, 6) do
      f when is_number(f) -> f
      _ -> 0.0
    end
  end
  defp extract_fitness(_), do: 0.0
end
