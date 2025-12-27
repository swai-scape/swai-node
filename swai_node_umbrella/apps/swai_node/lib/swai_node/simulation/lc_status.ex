defmodule SwaiNode.Simulation.LCStatus do
  @moduledoc """
  Query status of all Liquid Conglomerate silos.

  Provides real-time visibility into the 13 silos of the LC system:

  **Core Silos (Always Enabled):**
  - task_silo: Evolution optimization (hyperparameters)
  - resource_silo: System stability (compute resources)

  **Extension Silos (Optional):**
  - temporal_silo: Episode timing
  - competitive_silo: Opponent archives, Elo ratings
  - social_silo: Reputation, coalitions
  - cultural_silo: Innovations, traditions
  - ecological_silo: Niches, environmental stress
  - morphological_silo: Network complexity
  - developmental_silo: Ontogeny, plasticity
  - regulatory_silo: Gene expression
  - economic_silo: Compute budgets
  - communication_silo: Vocabulary evolution
  - distribution_silo: Mesh networking
  """

  require Logger

  @all_silos [
    :task,
    :resource,
    :temporal,
    :competitive,
    :social,
    :cultural,
    :ecological,
    :morphological,
    :developmental,
    :regulatory,
    :economic,
    :communication,
    :distribution
  ]

  @silo_descriptions %{
    task: "Evolution Optimization",
    resource: "System Stability",
    temporal: "Episode Timing",
    competitive: "Opponent Archives",
    social: "Reputation & Coalitions",
    cultural: "Innovations & Traditions",
    ecological: "Niches & Stress",
    morphological: "Network Complexity",
    developmental: "Ontogeny & Plasticity",
    regulatory: "Gene Expression",
    economic: "Compute Budgets",
    communication: "Vocabulary Evolution",
    distribution: "Mesh Networking"
  }

  @silo_time_constants %{
    task: 50,
    resource: 5,
    temporal: 10,
    competitive: 50,
    social: 50,
    cultural: 100,
    ecological: 100,
    morphological: 30,
    developmental: 100,
    regulatory: 50,
    economic: 20,
    communication: 30,
    distribution: 1
  }

  @doc """
  Get status of all silos with their enabled state and key metrics.
  """
  @spec get_all_silos() :: [map()]
  def get_all_silos do
    enabled_silos = get_enabled_silos()

    Enum.map(@all_silos, fn silo_type ->
      enabled = silo_type in enabled_silos

      base = %{
        type: silo_type,
        name: Atom.to_string(silo_type) |> String.replace("_", " ") |> String.capitalize(),
        description: Map.get(@silo_descriptions, silo_type, ""),
        time_constant: Map.get(@silo_time_constants, silo_type, 0),
        enabled: enabled,
        core: silo_type in [:task, :resource]
      }

      if enabled do
        Map.merge(base, get_silo_state(silo_type))
      else
        base
      end
    end)
  end

  @doc """
  Get list of currently enabled silos.
  """
  @spec get_enabled_silos() :: [atom()]
  def get_enabled_silos do
    try do
      :lc_supervisor.list_enabled_silos()
    catch
      :exit, _ -> [:task, :resource]
    end
  end

  @doc """
  Get detailed state for a specific silo.
  """
  @spec get_silo_state(atom()) :: map()
  def get_silo_state(:task) do
    case Process.whereis(:task_silo) do
      nil ->
        %{status: :not_running}

      pid ->
        try do
          state = :task_silo.get_state(pid)
          %{
            status: :running,
            stagnation_severity: Map.get(state, :stagnation_severity, 0.0),
            velocity: Map.get(state, :avg_velocity, 0.0),
            mutation_rate: get_in(state, [:config, :mutation_rate]) || 0.1,
            mutation_strength: get_in(state, [:config, :mutation_strength]) || 0.3,
            total_evaluations: Map.get(state, :total_evaluations, 0)
          }
        catch
          :exit, _ -> %{status: :error}
        end
    end
  end

  def get_silo_state(:resource) do
    case Process.whereis(:resource_silo) do
      nil ->
        %{status: :not_running}

      pid ->
        try do
          state = :resource_silo.get_state(pid)
          %{
            status: :running,
            concurrency: Map.get(state, :current_concurrency, 0),
            cpu_pressure: Map.get(state, :cpu_pressure, 0.0),
            memory_pressure: Map.get(state, :memory_pressure, 0.0)
          }
        catch
          :exit, _ -> %{status: :error}
        end
    end
  end

  def get_silo_state(silo_type) do
    module = silo_module(silo_type)

    case Process.whereis(module) do
      nil ->
        %{status: :not_running}

      pid ->
        try do
          state = apply(module, :get_state, [pid])
          %{
            status: :running,
            state: summarize_state(state)
          }
        catch
          :exit, _ -> %{status: :error}
        end
    end
  end

  @doc """
  Enable an extension silo at runtime.
  """
  @spec enable_silo(atom()) :: :ok | {:error, term()}
  def enable_silo(silo_type) when silo_type in [:task, :resource] do
    {:error, :core_silo_always_enabled}
  end

  def enable_silo(silo_type) do
    try do
      :lc_supervisor.enable_silo(silo_type)
    catch
      :exit, reason -> {:error, reason}
    end
  end

  @doc """
  Disable an extension silo at runtime.
  """
  @spec disable_silo(atom()) :: :ok | {:error, term()}
  def disable_silo(silo_type) when silo_type in [:task, :resource] do
    {:error, :cannot_disable_core_silo}
  end

  def disable_silo(silo_type) do
    try do
      :lc_supervisor.disable_silo(silo_type)
    catch
      :exit, reason -> {:error, reason}
    end
  end

  @doc """
  Enable all extension silos.
  """
  @spec enable_all_extensions() :: {:ok, [atom()]} | {:error, term()}
  def enable_all_extensions do
    extension_silos = @all_silos -- [:task, :resource]

    results = Enum.map(extension_silos, fn silo ->
      case enable_silo(silo) do
        :ok -> {:ok, silo}
        {:error, reason} -> {:error, silo, reason}
      end
    end)

    enabled = results
              |> Enum.filter(fn
                {:ok, _} -> true
                _ -> false
              end)
              |> Enum.map(fn {:ok, silo} -> silo end)

    Logger.info("[LCStatus] Enabled #{length(enabled)}/#{length(extension_silos)} extension silos")
    {:ok, enabled}
  end

  @doc """
  Get summary for dashboard display.
  """
  @spec dashboard_summary() :: map()
  def dashboard_summary do
    silos = get_all_silos()
    enabled_count = Enum.count(silos, & &1.enabled)
    core_count = Enum.count(silos, & &1.core)

    task_silo = Enum.find(silos, &(&1.type == :task))

    %{
      total: length(silos),
      enabled: enabled_count,
      core: core_count,
      extension: enabled_count - core_count,
      silos: silos,
      stagnation_severity: get_in(task_silo, [:stagnation_severity]) || 0.0,
      velocity: get_in(task_silo, [:velocity]) || 0.0
    }
  end

  # Private functions

  defp silo_module(:task), do: :task_silo
  defp silo_module(:resource), do: :resource_silo
  defp silo_module(:temporal), do: :temporal_silo
  defp silo_module(:competitive), do: :competitive_silo
  defp silo_module(:social), do: :social_silo
  defp silo_module(:cultural), do: :cultural_silo
  defp silo_module(:ecological), do: :ecological_silo
  defp silo_module(:morphological), do: :morphological_silo
  defp silo_module(:developmental), do: :developmental_silo
  defp silo_module(:regulatory), do: :regulatory_silo
  defp silo_module(:economic), do: :economic_silo
  defp silo_module(:communication), do: :communication_silo
  defp silo_module(:distribution), do: :distribution_silo

  defp summarize_state(state) when is_map(state) do
    # Extract key metrics if available
    state
    |> Map.take([:stagnation_severity, :velocity, :current_value, :pressure])
    |> Map.new(fn {k, v} -> {k, format_value(v)} end)
  end

  defp summarize_state(_), do: %{}

  defp format_value(v) when is_float(v), do: Float.round(v, 3)
  defp format_value(v), do: v
end
