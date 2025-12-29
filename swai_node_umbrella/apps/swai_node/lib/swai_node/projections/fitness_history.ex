defmodule SwaiNode.Projections.FitnessHistory do
  @moduledoc """
  Projection that builds a read model of fitness history from neuroevolution events.

  Subscribes to training events and maintains a time-series of fitness values
  for visualization and analysis.

  ## Read Model

  The projection maintains:
  - Last N generation stats (configurable, default 500)
  - Running averages
  - Peak fitness tracking

  ## Usage

      # Get recent history
      FitnessHistory.get_history()

      # Get history for specific range
      FitnessHistory.get_history(from: 100, to: 200)

      # Get summary stats
      FitnessHistory.get_summary()
  """

  use GenServer
  require Logger

  @pubsub SwaiNode.PubSub
  @topic "training:events"
  @max_history 500

  # ===========================================================================
  # Client API
  # ===========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get fitness history (most recent first)"
  def get_history(opts \\ []) do
    GenServer.call(__MODULE__, {:get_history, opts})
  end

  @doc "Get summary statistics"
  def get_summary do
    GenServer.call(__MODULE__, :get_summary)
  end

  @doc "Clear history (e.g., on training reset)"
  def clear do
    GenServer.cast(__MODULE__, :clear)
  end

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl true
  def init(_opts) do
    # Subscribe to training events
    Phoenix.PubSub.subscribe(@pubsub, @topic)

    state = %{
      history: [],
      peak_fitness: 0.0,
      peak_generation: 0,
      total_generations: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:get_history, opts}, _from, state) do
    history = filter_history(state.history, opts)
    {:reply, history, state}
  end

  @impl true
  def handle_call(:get_summary, _from, state) do
    summary = build_summary(state)
    {:reply, summary, state}
  end

  @impl true
  def handle_cast(:clear, _state) do
    {:noreply, %{
      history: [],
      peak_fitness: 0.0,
      peak_generation: 0,
      total_generations: 0
    }}
  end

  # ===========================================================================
  # Event Handlers
  # ===========================================================================

  @impl true
  def handle_info({:generation_complete, stats}, state) do
    point = %{
      generation: stats.generation,
      best_fitness: stats.best_fitness,
      avg_fitness: stats.avg_fitness,
      population: stats.population,
      timestamp: System.system_time(:millisecond)
    }

    # Update history (keep last N)
    history = [point | state.history] |> Enum.take(@max_history)

    # Track peak
    {peak_fitness, peak_generation} =
      if stats.best_fitness > state.peak_fitness do
        {stats.best_fitness, stats.generation}
      else
        {state.peak_fitness, state.peak_generation}
      end

    new_state = %{state |
      history: history,
      peak_fitness: peak_fitness,
      peak_generation: peak_generation,
      total_generations: stats.generation
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:training_reset, _}, _state) do
    {:noreply, %{
      history: [],
      peak_fitness: 0.0,
      peak_generation: 0,
      total_generations: 0
    }}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp filter_history(history, opts) do
    from_gen = Keyword.get(opts, :from, 0)
    to_gen = Keyword.get(opts, :to, :infinity)
    limit = Keyword.get(opts, :limit, @max_history)

    history
    |> Enum.filter(fn point ->
      point.generation >= from_gen and
        (to_gen == :infinity or point.generation <= to_gen)
    end)
    |> Enum.take(limit)
  end

  defp build_summary(state) do
    recent = Enum.take(state.history, 50)

    avg_best = if recent == [], do: 0.0, else: Enum.sum(Enum.map(recent, & &1.best_fitness)) / length(recent)
    avg_avg = if recent == [], do: 0.0, else: Enum.sum(Enum.map(recent, & &1.avg_fitness)) / length(recent)

    %{
      total_generations: state.total_generations,
      peak_fitness: state.peak_fitness,
      peak_generation: state.peak_generation,
      recent_avg_best: Float.round(avg_best, 2),
      recent_avg_avg: Float.round(avg_avg, 2),
      history_size: length(state.history)
    }
  end
end
