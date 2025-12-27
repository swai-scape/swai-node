defmodule SwaiNode.Simulation.SiloIntegration do
  @moduledoc """
  Integration with macula-neuroevolution's Liquid Conglomerate task_silo.

  The task_silo adaptively tunes evolution hyperparameters based on
  stagnation detection and improvement velocity. This module provides
  the interface between our WorldServer and the LC system.

  ## Usage

      # Report stats after each generation equivalent
      SiloIntegration.report_stats(%{
        best_fitness: 1500.0,
        avg_fitness: 800.0,
        improvement: 50.0,
        total_evaluations: 1000
      })

      # Get current recommendations for mutation
      %{mutation_rate: mr, mutation_strength: ms} = SiloIntegration.get_recommendations()
  """

  require Logger

  @doc """
  Report current evolution statistics to the task_silo.

  This updates the silo's internal state so it can compute
  appropriate hyperparameter recommendations.
  """
  @spec report_stats(map()) :: :ok
  def report_stats(stats) when is_map(stats) do
    case find_task_silo() do
      nil ->
        Logger.debug("[SiloIntegration] task_silo not found, skipping stats report")
        :ok

      pid ->
        :task_silo.update_stats(pid, stats)
    end
  end

  @doc """
  Get recommended hyperparameters from the task_silo.

  Returns a map with:
  - mutation_rate: Probability of mutating each weight (0.01 - 0.50)
  - mutation_strength: Magnitude of weight perturbations (0.05 - 1.0)
  - add_node_rate: Probability of adding network nodes (TWEANN)
  - selection_ratio: Fraction of population to keep

  Returns defaults if task_silo is not available.
  """
  @spec get_recommendations() :: map()
  def get_recommendations do
    case find_task_silo() do
      nil ->
        Logger.debug("[SiloIntegration] task_silo not found, using defaults")
        get_defaults()

      pid ->
        try do
          :task_silo.get_recommendations(pid)
        catch
          :exit, _ ->
            Logger.warning("[SiloIntegration] task_silo call failed, using defaults")
            get_defaults()
        end
    end
  end

  @doc """
  Get recommended parameters with current stats in one call.

  This is more efficient than separate report_stats + get_recommendations
  as it updates state and computes recommendations atomically.
  """
  @spec get_recommendations(map()) :: map()
  def get_recommendations(stats) when is_map(stats) do
    case find_task_silo() do
      nil ->
        get_defaults()

      pid ->
        try do
          :task_silo.get_recommendations(pid, stats)
        catch
          :exit, _ ->
            get_defaults()
        end
    end
  end

  @doc """
  Get current task_silo state for debugging/monitoring.
  """
  @spec get_state() :: map() | nil
  def get_state do
    case find_task_silo() do
      nil -> nil
      pid -> :task_silo.get_state(pid)
    end
  end

  @doc """
  Check if task_silo is available and running.
  """
  @spec available?() :: boolean()
  def available? do
    find_task_silo() != nil
  end

  # Private functions

  defp find_task_silo do
    case Process.whereis(:task_silo) do
      nil -> nil
      pid when is_pid(pid) -> pid
    end
  end

  defp get_defaults do
    # Match task_l0_defaults.erl defaults
    %{
      mutation_rate: 0.10,
      mutation_strength: 0.30,
      selection_ratio: 0.20,
      add_node_rate: 0.03,
      add_connection_rate: 0.05,
      weight_perturb_rate: 0.90,
      weight_perturb_strength: 0.30
    }
  end
end
