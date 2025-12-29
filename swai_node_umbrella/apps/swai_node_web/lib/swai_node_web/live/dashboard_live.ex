defmodule SwaiNodeWeb.DashboardLive do
  @moduledoc """
  Dashboard LiveView for SwaiNode - 4-Quadrant Layout.

  Layout:
  - Header: Controls + key stats
  - Q1 (top-left): Arena canvas
  - Q2 (top-right): Population (behavioral types, age distribution, species)
  - Q3 (bottom-left): Fitness (time series, reward breakdown)
  - Q4 (bottom-right): Culture (diversity, communication, social)
  - Footer: Event log + insights
  """

  use SwaiNodeWeb, :live_view

  alias SwaiNode.Simulation.HexWorldServer
  alias SwaiNode.Training.TrainingServer

  @pubsub SwaiNode.PubSub
  @world_topic "world:state"
  @training_topic "training:events"
  @agent_moved_topic "agent:moved"
  @coevolution_topic "coevolution:fitness"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(@pubsub, @world_topic)
      Phoenix.PubSub.subscribe(@pubsub, @training_topic)
      Phoenix.PubSub.subscribe(@pubsub, @agent_moved_topic)
      Phoenix.PubSub.subscribe(@pubsub, @coevolution_topic)
    end

    # Get initial state from both servers
    world_state = HexWorldServer.get_state()
    world_stats = HexWorldServer.get_stats()
    training_stats = TrainingServer.get_stats()
    training_running = TrainingServer.running?()

    # Arena config (replaces geo config)
    arena_radius = world_state[:config][:arena_radius] || 25
    hex_size = world_state[:config][:hex_size] || 12

    socket =
      socket
      |> assign(:world_state, world_state)
      |> assign(:world_stats, world_stats)
      |> assign(:training_stats, training_stats)
      |> assign(:training_running, training_running)
      |> assign(:arena_radius, arena_radius)
      |> assign(:hex_size, hex_size)
      # Population tracking
      |> assign(:behavioral_types, %{herbivore: 0, omnivore: 0, carnivore: 0})
      |> assign(:type_history, [])
      |> assign(:age_distribution, List.duplicate(0, 10))
      |> assign(:species_distribution, [])
      # Fitness tracking
      |> assign(:fitness_history, [])
      |> assign(:reward_breakdown, %{survival: 0, eating: 0, killing: 0, cooperation: 0, diplomacy: 0})
      # Coevolution tracking (multi-species)
      |> assign(:coevolution_fitness_history, [])
      # Culture tracking
      |> assign(:diversity_history, [])
      |> assign(:signal_distribution, List.duplicate(0, 10))
      |> assign(:social_metrics, %{cooperation_rate: 0.5, clustering: 0.0, coordination: 0.5})
      # Events
      |> assign(:events, [])
      |> assign(:champion_fitness, 0.0)
      |> assign(:audio_enabled, false)

    # Push initial arena state (walls + config) to frontend when connected
    socket =
      if connected?(socket) do
        walls = world_state[:walls] || []
        push_event(socket, "arena_init", %{
          walls: walls,
          config: %{arena_radius: arena_radius, hex_size: hex_size}
        })
      else
        socket
      end

    {:ok, socket}
  end

  # ==========================================================================
  # World Events (visualization)
  # ==========================================================================

  @impl true
  def handle_info({:arena_init, data}, socket) do
    # Push arena initialization to frontend (walls and config)
    socket = push_event(socket, "arena_init", data)
    {:noreply, socket}
  end

  # ==========================================================================
  # Agent Movement Events (fine-grained updates)
  # ==========================================================================

  @impl true
  def handle_info(%{type: :agent_moved} = event, socket) do
    # Push individual movement event to frontend
    socket = push_event(socket, "agent_moved", %{
      agent_id: event.agent_id,
      from_hex: Tuple.to_list(event.from_hex),
      to_hex: Tuple.to_list(event.to_hex),
      direction: event.direction,
      tick: event.tick
    })
    {:noreply, socket}
  end

  @impl true
  def handle_info({:world_update, world_state}, socket) do
    existing = socket.assigns.world_state
    merged_state = Map.merge(existing, world_state)

    food_maps = convert_food_to_maps(world_state[:food] || [])
    agents_list = world_state[:agents] || []
    new_stats = build_stats_from_broadcast(world_state, socket.assigns.world_stats)

    # Get behavioral types from broadcast
    behavioral_types = world_state[:behavioral_types] || socket.assigns.behavioral_types

    # Track histories
    tick = world_state[:tick] || 0
    type_history = update_type_history(socket.assigns.type_history, tick, behavioral_types)

    # Calculate distributions from agents
    age_distribution = calculate_age_distribution(agents_list)
    species_distribution = calculate_species_distribution(world_state[:species] || [])
    signal_distribution = calculate_signal_distribution(agents_list)

    # Calculate social metrics
    social_metrics = %{
      cooperation_rate: new_stats[:cooperation_rate] || 0.5,
      clustering: world_state[:diversity] || 0.0,
      coordination: calculate_signal_coordination(agents_list)
    }

    # Track diversity history
    diversity = world_state[:diversity] || 0.0
    diversity_history = update_diversity_history(socket.assigns.diversity_history, tick, diversity)

    # Events data for canvas
    events = socket.assigns.events

    socket =
      socket
      |> assign(:world_state, merged_state)
      |> assign(:world_stats, new_stats)
      |> assign(:behavioral_types, behavioral_types)
      |> assign(:type_history, type_history)
      |> assign(:age_distribution, age_distribution)
      |> assign(:species_distribution, species_distribution)
      |> assign(:signal_distribution, signal_distribution)
      |> assign(:social_metrics, social_metrics)
      |> assign(:diversity_history, diversity_history)
      |> push_event("world_update", %{
        agents: agents_list,
        food: food_maps,
        events: Enum.take(events, 5),
        champion_fitness: socket.assigns.champion_fitness
      })

    {:noreply, socket}
  end

  # ==========================================================================
  # Training Events (evolution)
  # ==========================================================================

  @impl true
  def handle_info({:generation_complete, stats}, socket) do
    generation = stats.generation
    best = stats.best_fitness
    avg = stats.avg_fitness

    point = %{generation: generation, best: best, avg: avg}
    fitness_history = [point | socket.assigns.fitness_history] |> Enum.take(100)

    # Update reward breakdown from stats if available
    reward_breakdown = Map.get(stats, :reward_breakdown, socket.assigns.reward_breakdown)

    # Check for new champion
    events = socket.assigns.events
    champion_fitness = socket.assigns.champion_fitness
    {events, champion_fitness, is_new_champion} =
      if best > champion_fitness * 1.1 and best > 100 do
        event = %{type: :champion, fitness: best, generation: generation, time: now()}
        {[event | events] |> Enum.take(20), best, true}
      else
        {events, max(champion_fitness, best), false}
      end

    socket =
      socket
      |> assign(:training_stats, stats)
      |> assign(:fitness_history, fitness_history)
      |> assign(:reward_breakdown, reward_breakdown)
      |> assign(:events, events)
      |> assign(:champion_fitness, champion_fitness)
      |> push_chart_update()
      |> then(fn s ->
        if is_new_champion do
          push_event(s, "evolution_event", %{type: "champion", data: %{fitness: best, generation: generation}})
        else
          s
        end
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:training_started, _config}, socket) do
    {:noreply, assign(socket, :training_running, true)}
  end

  @impl true
  def handle_info({:training_stopped, _stats}, socket) do
    {:noreply, assign(socket, :training_running, false)}
  end

  @impl true
  def handle_info({:training_complete, _stats}, socket) do
    {:noreply, assign(socket, :training_running, false)}
  end

  @impl true
  def handle_info({:training_reset, _}, socket) do
    socket =
      socket
      |> assign(:training_running, false)
      |> assign(:fitness_history, [])
      |> assign(:diversity_history, [])
      |> assign(:coevolution_fitness_history, [])
      |> assign(:events, [])
      |> assign(:champion_fitness, 0.0)
      |> assign(:training_stats, %{generation: 0, best_fitness: 0.0, avg_fitness: 0.0, population: 0})

    {:noreply, socket}
  end

  @impl true
  def handle_info({:species_created, species_info}, socket) do
    event = %{type: :speciation, species: species_info, time: now()}
    events = [event | socket.assigns.events] |> Enum.take(20)
    socket =
      socket
      |> assign(:events, events)
      |> push_event("evolution_event", %{type: "speciation", data: species_info})
    {:noreply, socket}
  end

  # ==========================================================================
  # Coevolution Events (multi-species fitness tracking)
  # ==========================================================================

  @impl true
  def handle_info({:coevolution_generation, gen_data}, socket) do
    # gen_data: %{generation: N, forager: %{best: F, avg: A}, predator: %{best: F, avg: A}}
    point = %{
      generation: gen_data.generation,
      forager_best: gen_data.forager.best,
      forager_avg: gen_data.forager.avg,
      predator_best: gen_data.predator.best,
      predator_avg: gen_data.predator.avg
    }

    coevolution_history = [point | socket.assigns.coevolution_fitness_history] |> Enum.take(100)

    socket =
      socket
      |> assign(:coevolution_fitness_history, coevolution_history)
      |> push_event("update-chart-coevolution-chart", %{options: build_coevolution_chart(coevolution_history)})

    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ==========================================================================
  # User Events (controls)
  # ==========================================================================

  @impl true
  def handle_event("start", _params, socket) do
    # Start world simulation
    HexWorldServer.play()
    HexWorldServer.set_mode(:realtime)

    # Try to start training (may fail if TrainingServer has issues)
    training_running =
      try do
        TrainingServer.start_training()
        true
      rescue
        _ -> false
      catch
        :exit, _ -> false
      end

    socket =
      socket
      |> update_world_state()
      |> assign(:training_running, training_running)

    {:noreply, socket}
  end

  @impl true
  def handle_event("reset", _params, socket) do
    # Reset everything
    HexWorldServer.reset()
    TrainingServer.reset()

    socket =
      socket
      |> update_world_state()
      |> assign(:training_running, false)
      |> assign(:type_history, [])
      |> assign(:diversity_history, [])
      |> assign(:fitness_history, [])
      |> assign(:coevolution_fitness_history, [])
      |> assign(:events, [])
      |> assign(:champion_fitness, 0.0)
      |> assign(:training_stats, %{generation: 0, best_fitness: 0.0, avg_fitness: 0.0, population: 0})

    {:noreply, socket}
  end

  # ==========================================================================
  # Chart Helpers
  # ==========================================================================

  defp push_chart_update(socket) do
    socket
    |> push_event("update-chart-fitness-chart", %{options: build_fitness_chart(socket.assigns.fitness_history)})
    |> push_event("update-chart-population-chart", %{options: build_population_chart(socket.assigns.type_history)})
    |> push_event("update-chart-diversity-chart", %{options: build_diversity_chart(socket.assigns.diversity_history)})
  end

  defp build_fitness_chart(history) do
    reversed = Enum.reverse(history)
    generations = Enum.map(reversed, & &1.generation)
    best_data = Enum.map(reversed, & &1.best)
    avg_data = Enum.map(reversed, & &1.avg)

    %{
      animation: false,
      grid: %{left: 35, right: 5, top: 5, bottom: 20},
      xAxis: %{type: "category", data: generations, axisLabel: %{fontSize: 9, show: false}},
      yAxis: %{type: "value", axisLabel: %{fontSize: 9}},
      series: [
        %{name: "Best", type: "line", data: best_data, smooth: true, lineStyle: %{width: 2}, showSymbol: false, areaStyle: %{opacity: 0.1}, itemStyle: %{color: "#eab308"}},
        %{name: "Avg", type: "line", data: avg_data, smooth: true, lineStyle: %{width: 1, type: "dashed"}, showSymbol: false, itemStyle: %{color: "#22c55e"}}
      ]
    }
  end

  defp build_population_chart(history) do
    reversed = Enum.reverse(history)
    ticks = Enum.map(reversed, & &1.tick)

    %{
      animation: false,
      grid: %{left: 35, right: 5, top: 5, bottom: 20},
      xAxis: %{type: "category", data: ticks, axisLabel: %{show: false}},
      yAxis: %{type: "value", axisLabel: %{fontSize: 9}},
      series: [
        %{name: "Herb", type: "line", stack: "pop", data: Enum.map(reversed, & &1.herbivore), smooth: true, showSymbol: false, areaStyle: %{opacity: 0.6}, lineStyle: %{width: 1}, itemStyle: %{color: "#22c55e"}},
        %{name: "Omni", type: "line", stack: "pop", data: Enum.map(reversed, & &1.omnivore), smooth: true, showSymbol: false, areaStyle: %{opacity: 0.6}, lineStyle: %{width: 1}, itemStyle: %{color: "#eab308"}},
        %{name: "Carn", type: "line", stack: "pop", data: Enum.map(reversed, & &1.carnivore), smooth: true, showSymbol: false, areaStyle: %{opacity: 0.6}, lineStyle: %{width: 1}, itemStyle: %{color: "#ef4444"}}
      ]
    }
  end

  defp build_diversity_chart(history) do
    reversed = Enum.reverse(history)
    ticks = Enum.map(reversed, & &1.tick)
    values = Enum.map(reversed, & &1.diversity)

    %{
      animation: false,
      grid: %{left: 35, right: 5, top: 5, bottom: 20},
      xAxis: %{type: "category", data: ticks, axisLabel: %{show: false}},
      yAxis: %{type: "value", min: 0, max: 1, axisLabel: %{fontSize: 9}},
      series: [
        %{name: "Diversity", type: "line", data: values, smooth: true, lineStyle: %{width: 2}, showSymbol: false, areaStyle: %{opacity: 0.2}, itemStyle: %{color: "#8b5cf6"}}
      ]
    }
  end

  defp build_coevolution_chart(history) do
    reversed = Enum.reverse(history)
    generations = Enum.map(reversed, & &1.generation)
    forager_best = Enum.map(reversed, & &1.forager_best)
    forager_avg = Enum.map(reversed, & &1.forager_avg)
    predator_best = Enum.map(reversed, & &1.predator_best)
    predator_avg = Enum.map(reversed, & &1.predator_avg)

    %{
      animation: false,
      grid: %{left: 35, right: 5, top: 25, bottom: 20},
      legend: %{
        data: ["Forager Best", "Forager Avg", "Predator Best", "Predator Avg"],
        top: 0,
        textStyle: %{fontSize: 8, color: "#9ca3af"}
      },
      xAxis: %{type: "category", data: generations, axisLabel: %{fontSize: 9, show: false}},
      yAxis: %{type: "value", axisLabel: %{fontSize: 9}},
      series: [
        %{name: "Forager Best", type: "line", data: forager_best, smooth: true, lineStyle: %{width: 2}, showSymbol: false, itemStyle: %{color: "#22c55e"}},
        %{name: "Forager Avg", type: "line", data: forager_avg, smooth: true, lineStyle: %{width: 1, type: "dashed"}, showSymbol: false, itemStyle: %{color: "#22c55e"}, opacity: 0.6},
        %{name: "Predator Best", type: "line", data: predator_best, smooth: true, lineStyle: %{width: 2}, showSymbol: false, itemStyle: %{color: "#ef4444"}},
        %{name: "Predator Avg", type: "line", data: predator_avg, smooth: true, lineStyle: %{width: 1, type: "dashed"}, showSymbol: false, itemStyle: %{color: "#ef4444"}, opacity: 0.6}
      ]
    }
  end

  # ==========================================================================
  # Distribution Calculators
  # ==========================================================================

  defp calculate_age_distribution(agents) when is_list(agents) and length(agents) > 0 do
    # Bucket ages into 10 bins based on actual max age in population
    ages = Enum.map(agents, &Map.get(&1, :age, 0))
    max_age = max(Enum.max(ages), 100)  # At least 100 to avoid division issues
    bin_size = max_age / 10

    ages
    |> Enum.reduce(List.duplicate(0, 10), fn age, bins ->
      bin_idx = min(9, trunc(age / bin_size))
      List.update_at(bins, bin_idx, &(&1 + 1))
    end)
  end
  defp calculate_age_distribution(_), do: List.duplicate(0, 10)

  defp calculate_species_distribution(species) when is_list(species) and length(species) > 0 do
    species
    |> Enum.sort_by(fn s -> -Map.get(s, :count, 0) end)
    |> Enum.take(5)
    |> Enum.map(fn s ->
      hue = s[:color_hue] || 0
      %{
        id: s[:id] || 0,
        count: s[:count] || 0,
        color: "hsl(#{hue}, 70%, 50%)"
      }
    end)
  end
  defp calculate_species_distribution(_), do: []

  defp calculate_signal_distribution(agents) when is_list(agents) and length(agents) > 0 do
    # Bucket signals into 10 bins (0.0-0.1, 0.1-0.2, etc.)
    agents
    |> Enum.map(&Map.get(&1, :signal, 0.5))
    |> Enum.reduce(List.duplicate(0, 10), fn signal, bins ->
      bin_idx = min(9, trunc(signal * 10))
      List.update_at(bins, bin_idx, &(&1 + 1))
    end)
  end
  defp calculate_signal_distribution(_), do: List.duplicate(0, 10)

  defp calculate_signal_coordination(agents) when is_list(agents) and length(agents) > 1 do
    signals = Enum.map(agents, &Map.get(&1, :signal, 0.5))
    mean = Enum.sum(signals) / length(signals)
    variance = Enum.sum(Enum.map(signals, fn s -> (s - mean) * (s - mean) end)) / length(signals)
    # Low variance = high coordination
    max(0.0, 1.0 - :math.sqrt(variance) * 3)
  end
  defp calculate_signal_coordination(_), do: 0.5

  # ==========================================================================
  # History Tracking
  # ==========================================================================

  defp update_type_history(history, tick, types) do
    point = %{tick: tick, herbivore: types.herbivore, omnivore: types.omnivore, carnivore: types.carnivore}
    [point | history] |> Enum.take(100)
  end

  defp update_diversity_history(history, tick, diversity) do
    point = %{tick: tick, diversity: diversity}
    [point | history] |> Enum.take(100)
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp convert_food_to_maps(food) when is_list(food) do
    Enum.map(food, fn
      {x, y, energy} -> %{x: x, y: y, energy: energy}
      %{x: _, y: _, energy: _} = map -> map
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end
  defp convert_food_to_maps(_), do: []

  defp build_stats_from_broadcast(world_state, existing_stats) do
    broadcast_stats = Map.get(world_state, :stats, %{})
    %{
      population: world_state[:population] || existing_stats[:population] || 0,
      tick: world_state[:tick] || existing_stats[:tick] || 0,
      generation: world_state[:generation] || existing_stats[:generation] || 0,
      best_fitness: broadcast_stats[:best_fitness] || existing_stats[:best_fitness] || 0.0,
      avg_fitness: broadcast_stats[:avg_fitness] || existing_stats[:avg_fitness] || 0.0,
      total_births: broadcast_stats[:births] || existing_stats[:total_births] || 0,
      total_deaths: broadcast_stats[:deaths] || existing_stats[:total_deaths] || 0,
      total_kills: broadcast_stats[:kills] || existing_stats[:total_kills] || 0,
      cooperation_rate: broadcast_stats[:cooperation_rate] || existing_stats[:cooperation_rate],
      diplomacy_rate: broadcast_stats[:diplomacy_rate] || existing_stats[:diplomacy_rate],
      food_count: length(world_state[:food] || [])
    }
  end

  defp update_world_state(socket) do
    world_state = HexWorldServer.get_state()
    stats = HexWorldServer.get_stats()

    socket
    |> assign(:world_state, world_state)
    |> assign(:world_stats, stats)
  end

  defp now, do: System.monotonic_time(:millisecond)

  # ==========================================================================
  # Render
  # ==========================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen bg-gray-900 text-white flex flex-col overflow-hidden">
      <!-- HEADER: Node Stats -->
      <header class="bg-gray-800 border-b border-gray-700 px-4 py-2 flex-shrink-0">
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-4">
            <h1 class="text-lg font-bold text-purple-400">SwaiNode</h1>
            <div class="flex items-center gap-2">
              <button phx-click="start" class="px-3 py-1 rounded text-sm font-medium bg-green-600 hover:bg-green-500">
                Start
              </button>
              <button phx-click="reset" class="px-3 py-1 rounded text-sm font-medium bg-red-600 hover:bg-red-500">
                Reset
              </button>
            </div>
          </div>
          <div class="flex items-center gap-6 text-sm">
            <div class="flex items-center gap-2">
              <span class="text-gray-500">Tick:</span>
              <span class="text-white font-mono">{@world_stats.tick}</span>
            </div>
            <div class="flex items-center gap-2">
              <span class="text-gray-500">Agents:</span>
              <span class="text-green-400 font-mono">{@world_stats.population}</span>
            </div>
            <div class="flex items-center gap-2">
              <span class="text-gray-500">Generation:</span>
              <span class="text-purple-400 font-mono">{@training_stats[:generation] || 0}</span>
            </div>
          </div>
        </div>
      </header>

      <!-- MAIN: Split Screen - Arena (2/3) + Insights (1/3) -->
      <main class="flex-1 min-h-0 flex">
        <!-- Left: Hex Arena (2/3 width) -->
        <div class="w-2/3 h-full" id="arena-container" phx-update="ignore">
          <div
            id="hex-arena"
            phx-hook="HexArena"
            data-arena-radius={@arena_radius}
            data-hex-size={@hex_size}
            class="w-full h-full bg-gray-900"
          >
            <canvas class="w-full h-full"></canvas>
          </div>
        </div>

        <!-- Right: Insights Panel (1/3 width) -->
        <div class="w-1/3 h-full bg-gray-850 border-l border-gray-700 flex flex-col overflow-hidden">
          <!-- Legend -->
          <.legend_panel behavioral_types={@behavioral_types} world_stats={@world_stats} />

          <!-- AI Insights -->
          <.insights_panel
            world_stats={@world_stats}
            behavioral_types={@behavioral_types}
            social_metrics={@social_metrics}
            events={@events}
            champion_fitness={@champion_fitness}
          />

          <!-- Population Charts -->
          <.charts_panel
            fitness_history={@fitness_history}
            type_history={@type_history}
            diversity_history={@diversity_history}
          />
        </div>
      </main>

      <!-- FOOTER: Quick Stats -->
      <footer class="bg-gray-800 border-t border-gray-700 px-4 py-2 flex-shrink-0">
        <div class="flex items-center justify-between text-sm">
          <div class="flex items-center gap-6">
            <div class="flex items-center gap-2">
              <span class="text-gray-500">Arena:</span>
              <span class="text-cyan-400 font-mono">Hex r={@arena_radius}</span>
            </div>
            <div class="flex items-center gap-2">
              <span class="text-gray-500">Best Fitness:</span>
              <span class="text-yellow-400 font-mono">{format_number(@training_stats[:best_fitness] || 0)}</span>
            </div>
          </div>
          <div class="flex items-center gap-6 text-gray-400">
            <span>Born: <span class="text-green-400">{@world_stats.total_births}</span></span>
            <span>Hunted: <span class="text-red-400">{@world_stats.total_kills}</span></span>
            <span>Starved: <span class="text-orange-400">{@world_stats.total_deaths}</span></span>
          </div>
        </div>
      </footer>
    </div>
    """
  end

  # ==========================================================================
  # Panel Components
  # ==========================================================================

  defp legend_panel(assigns) do
    ~H"""
    <div class="p-4 border-b border-gray-700">
      <h3 class="text-sm font-semibold text-gray-400 mb-3 flex items-center gap-2">
        <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 20l-5.447-2.724A1 1 0 013 16.382V5.618a1 1 0 011.447-.894L9 7m0 13l6-3m-6 3V7m6 10l4.553 2.276A1 1 0 0021 18.382V7.618a1 1 0 00-.553-.894L15 4m0 13V4m0 0L9 7"/>
        </svg>
        Legend
      </h3>

      <div class="space-y-3">
        <!-- Agents Section -->
        <div>
          <div class="text-xs text-gray-500 mb-2">Agents by Behavior</div>
          <div class="space-y-1.5">
            <div class="flex items-center gap-2">
              <svg class="w-3 h-3" viewBox="0 0 12 12">
                <circle cx="6" cy="6" r="5" fill="#22c55e" stroke="#16a34a" stroke-width="1"/>
              </svg>
              <span class="text-xs text-gray-300">Herbivore (circle)</span>
              <span class="text-xs text-green-400 font-mono ml-auto">{@behavioral_types.herbivore}</span>
            </div>
            <div class="flex items-center gap-2">
              <svg class="w-3 h-3" viewBox="0 0 12 12">
                <polygon points="6,1 11,6 6,11 1,6" fill="#eab308" stroke="#ca8a04" stroke-width="1"/>
              </svg>
              <span class="text-xs text-gray-300">Omnivore (diamond)</span>
              <span class="text-xs text-yellow-400 font-mono ml-auto">{@behavioral_types.omnivore}</span>
            </div>
            <div class="flex items-center gap-2">
              <svg class="w-3 h-3" viewBox="0 0 12 12">
                <polygon points="11,6 2,1 2,11" fill="#ef4444" stroke="#dc2626" stroke-width="1"/>
              </svg>
              <span class="text-xs text-gray-300">Carnivore (triangle)</span>
              <span class="text-xs text-red-400 font-mono ml-auto">{@behavioral_types.carnivore}</span>
            </div>
          </div>
        </div>

        <!-- Food Section -->
        <div>
          <div class="text-xs text-gray-500 mb-2">Resources</div>
          <div class="space-y-1.5">
            <div class="flex items-center gap-2">
              <div class="w-3 h-3 rounded-sm bg-emerald-400 shadow-[0_0_6px_rgba(52,211,153,0.5)]"></div>
              <span class="text-xs text-gray-300">Food</span>
              <span class="text-xs text-emerald-400 font-mono ml-auto">{@world_stats.food_count}</span>
            </div>
          </div>
        </div>

        <!-- Special Markers -->
        <div>
          <div class="text-xs text-gray-500 mb-2">Markers</div>
          <div class="space-y-1.5">
            <div class="flex items-center gap-2">
              <div class="w-3 h-3 rounded-full border-2 border-purple-500"></div>
              <span class="text-xs text-gray-300">Node Origin</span>
            </div>
            <div class="flex items-center gap-2">
              <div class="w-3 h-3 rounded-full bg-yellow-400 shadow-[0_0_8px_rgba(250,204,21,0.6)]"></div>
              <span class="text-xs text-gray-300">Champion</span>
            </div>
            <div class="flex items-center gap-2">
              <div class="w-3 h-3 rounded-full bg-red-500 shadow-[0_0_6px_rgba(239,68,68,0.5)]"></div>
              <span class="text-xs text-gray-300">Attacking</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp insights_panel(assigns) do
    insights = generate_insights(assigns)
    assigns = assign(assigns, :insights, insights)

    ~H"""
    <div class="p-4 border-b border-gray-700 flex-shrink-0">
      <h3 class="text-sm font-semibold text-gray-400 mb-3 flex items-center gap-2">
        <svg class="w-4 h-4 text-purple-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9.663 17h4.673M12 3v1m6.364 1.636l-.707.707M21 12h-1M4 12H3m3.343-5.657l-.707-.707m2.828 9.9a5 5 0 117.072 0l-.548.547A3.374 3.374 0 0014 18.469V19a2 2 0 11-4 0v-.531c0-.895-.356-1.754-.988-2.386l-.548-.547z"/>
        </svg>
        AI Insights
      </h3>

      <div class="space-y-2">
        <%= for insight <- @insights do %>
          <div class={["p-2 rounded text-xs", insight_class(insight.type)]}>
            <div class="flex items-start gap-2">
              <span class="text-base">{insight.icon}</span>
              <div>
                <div class="font-medium">{insight.title}</div>
                <div class="text-gray-400 mt-0.5">{insight.description}</div>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp charts_panel(assigns) do
    ~H"""
    <div class="flex-1 p-4 overflow-y-auto space-y-4">
      <!-- Coevolution Fitness Chart -->
      <div class="bg-gray-800 rounded-lg p-3">
        <div class="text-xs text-gray-500 mb-2 flex items-center gap-2">
          <span>🧬</span>
          <span>Coevolution: Forager vs Predator</span>
        </div>
        <div id="coevolution-chart" phx-hook="EChart" phx-update="ignore" class="h-32"></div>
      </div>

      <!-- Fitness Chart -->
      <div class="bg-gray-800 rounded-lg p-3">
        <div class="text-xs text-gray-500 mb-2">Fitness Over Time</div>
        <div id="fitness-chart" phx-hook="EChart" phx-update="ignore" class="h-24"></div>
      </div>

      <!-- Population Chart -->
      <div class="bg-gray-800 rounded-lg p-3">
        <div class="text-xs text-gray-500 mb-2">Population by Type</div>
        <div id="population-chart" phx-hook="EChart" phx-update="ignore" class="h-24"></div>
      </div>

      <!-- Diversity Chart -->
      <div class="bg-gray-800 rounded-lg p-3">
        <div class="text-xs text-gray-500 mb-2">Genetic Diversity</div>
        <div id="diversity-chart" phx-hook="EChart" phx-update="ignore" class="h-24"></div>
      </div>
    </div>
    """
  end

  # ==========================================================================
  # Insight Generation
  # ==========================================================================

  defp generate_insights(assigns) do
    insights = []

    # Population health insight
    population = assigns.world_stats.population || 0
    insights = if population == 0 do
      [%{type: :danger, icon: "💀", title: "Population Extinct", description: "All agents have died. Click Reset to restart."} | insights]
    else
      if population < 20 do
        [%{type: :warning, icon: "⚠️", title: "Low Population", description: "Only #{population} agents remain. Survival is critical."} | insights]
      else
        insights
      end
    end

    # Behavioral balance insight
    %{herbivore: h, omnivore: o, carnivore: c} = assigns.behavioral_types
    total = h + o + c
    insights = if total > 0 do
      carn_ratio = c / total
      cond do
        carn_ratio > 0.5 ->
          [%{type: :warning, icon: "🔴", title: "Predator Dominance", description: "#{round(carn_ratio * 100)}% carnivores may cause population collapse."} | insights]
        carn_ratio < 0.1 and c > 0 ->
          [%{type: :info, icon: "🌱", title: "Peaceful Ecosystem", description: "Herbivores dominate. Low predation pressure."} | insights]
        true ->
          insights
      end
    else
      insights
    end

    # Champion insight
    insights = if assigns.champion_fitness > 0 do
      [%{type: :success, icon: "🏆", title: "Champion Fitness: #{format_number(assigns.champion_fitness)}", description: "The fittest agent in the population."} | insights]
    else
      insights
    end

    # Social metrics insight
    coop_rate = assigns.social_metrics.cooperation_rate || 0.5
    insights = cond do
      coop_rate > 0.7 ->
        [%{type: :success, icon: "🤝", title: "High Cooperation", description: "Agents are frequently cooperating (#{round(coop_rate * 100)}%)."} | insights]
      coop_rate < 0.3 ->
        [%{type: :info, icon: "⚔️", title: "Competitive Environment", description: "Low cooperation (#{round(coop_rate * 100)}%). Survival of the fittest."} | insights]
      true ->
        insights
    end

    # Default insight if none
    if insights == [] do
      [%{type: :info, icon: "🧬", title: "Evolution in Progress", description: "Agents are evolving and adapting to the environment."}]
    else
      Enum.take(insights, 4)  # Limit to 4 insights
    end
  end

  defp insight_class(:danger), do: "bg-red-950/50 border border-red-900/50 text-red-300"
  defp insight_class(:warning), do: "bg-yellow-950/50 border border-yellow-900/50 text-yellow-300"
  defp insight_class(:success), do: "bg-green-950/50 border border-green-900/50 text-green-300"
  defp insight_class(:info), do: "bg-purple-950/50 border border-purple-900/50 text-purple-300"
  defp insight_class(_), do: "bg-gray-800 border border-gray-700 text-gray-300"

  # ==========================================================================
  # Components
  # ==========================================================================

  defp event_badge(assigns) do
    ~H"""
    <div class={["px-1.5 py-0.5 rounded text-[10px] font-medium animate-fade-in", event_badge_class(@event.type)]}>
      {event_badge_text(@event)}
    </div>
    """
  end

  defp histogram_bar(assigns) do
    max_val = Enum.max(assigns.data ++ [1])
    color_class = case assigns.color do
      "cyan" -> "bg-cyan-500"
      "blue" -> "bg-blue-500"
      "purple" -> "bg-purple-500"
      _ -> "bg-gray-500"
    end

    assigns = assign(assigns, :max_val, max_val)
    assigns = assign(assigns, :color_class, color_class)

    ~H"""
    <div class="flex-1 flex items-end gap-0.5 min-h-0">
      <%= for {val, _idx} <- Enum.with_index(@data) do %>
        <div class="flex-1 flex flex-col justify-end h-full">
          <div class={[@color_class, "w-full rounded-t-sm opacity-70"]}
            style={"height: #{if @max_val > 0, do: val / @max_val * 100, else: 0}%"} />
        </div>
      <% end %>
    </div>
    """
  end

  defp species_bars(assigns) do
    max_count = Enum.max(Enum.map(assigns.species, & &1.count) ++ [1])
    assigns = assign(assigns, :max_count, max_count)

    ~H"""
    <div class="flex-1 flex flex-col gap-0.5 min-h-0 justify-center">
      <%= if @species == [] do %>
        <div class="text-[10px] text-gray-600 text-center">No species data</div>
      <% else %>
        <%= for s <- @species do %>
          <div class="flex items-center gap-1 h-3">
            <span class="text-[9px] text-gray-500 w-6">S{s.id}</span>
            <div class="flex-1 bg-gray-700 rounded-full h-2 overflow-hidden">
              <div class="h-full rounded-full" style={"width: #{s.count / @max_count * 100}%; background-color: #{s.color}"} />
            </div>
            <span class="text-[9px] text-gray-400 w-6">{s.count}</span>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp reward_breakdown(assigns) do
    rewards = assigns.rewards
    total = Enum.sum(Map.values(rewards)) |> max(1)
    assigns = assign(assigns, :total, total)

    ~H"""
    <div class="flex-1 flex flex-col gap-0.5 min-h-0 justify-center">
      <.reward_bar name="Survival" value={@rewards[:survival] || 0} total={@total} color="bg-gray-500" />
      <.reward_bar name="Eating" value={@rewards[:eating] || 0} total={@total} color="bg-green-500" />
      <.reward_bar name="Killing" value={@rewards[:killing] || 0} total={@total} color="bg-red-500" />
      <.reward_bar name="Coop" value={@rewards[:cooperation] || 0} total={@total} color="bg-cyan-500" />
      <.reward_bar name="Diplo" value={@rewards[:diplomacy] || 0} total={@total} color="bg-blue-500" />
    </div>
    """
  end

  defp reward_bar(assigns) do
    pct = if assigns.total > 0, do: assigns.value / assigns.total * 100, else: 0
    assigns = assign(assigns, :pct, pct)

    ~H"""
    <div class="flex items-center gap-1 h-3">
      <span class="text-[9px] text-gray-500 w-10">{@name}</span>
      <div class="flex-1 bg-gray-700 rounded-full h-1.5 overflow-hidden">
        <div class={[@color, "h-full rounded-full"]} style={"width: #{@pct}%"} />
      </div>
      <span class="text-[9px] text-gray-400 w-8">{format_number(@value)}</span>
    </div>
    """
  end

  defp social_gauges(assigns) do
    ~H"""
    <div class="flex-1 flex items-center justify-around min-h-0">
      <.gauge label="Cooperation" value={@metrics.cooperation_rate || 0} color="green" />
      <.gauge label="Clustering" value={@metrics.clustering || 0} color="purple" />
      <.gauge label="Diplomacy" value={@diplomacy || 0} color="blue" />
    </div>
    """
  end

  defp gauge(assigns) do
    pct = (assigns.value || 0) * 100
    color_class = case assigns.color do
      "green" -> "text-green-400"
      "purple" -> "text-purple-400"
      "blue" -> "text-blue-400"
      _ -> "text-gray-400"
    end
    ring_color = case assigns.color do
      "green" -> "stroke-green-500"
      "purple" -> "stroke-purple-500"
      "blue" -> "stroke-blue-500"
      _ -> "stroke-gray-500"
    end
    assigns = assign(assigns, :pct, pct)
    assigns = assign(assigns, :color_class, color_class)
    assigns = assign(assigns, :ring_color, ring_color)
    # SVG circle: circumference = 2*pi*r, for r=20, C=125.66
    circumference = 125.66
    dash = pct / 100 * circumference
    assigns = assign(assigns, :dash, dash)
    assigns = assign(assigns, :circumference, circumference)

    ~H"""
    <div class="flex flex-col items-center">
      <svg class="w-10 h-10 -rotate-90" viewBox="0 0 44 44">
        <circle cx="22" cy="22" r="20" fill="none" stroke-width="3" class="stroke-gray-700" />
        <circle cx="22" cy="22" r="20" fill="none" stroke-width="3" class={@ring_color}
          stroke-linecap="round" stroke-dasharray={"#{@dash} #{@circumference}"} />
      </svg>
      <span class={["text-[9px] mt-0.5", @color_class]}>{trunc(@pct)}%</span>
      <span class="text-[8px] text-gray-500">{@label}</span>
    </div>
    """
  end

  # ==========================================================================
  # Event Formatting
  # ==========================================================================

  defp event_badge_class(:champion), do: "bg-yellow-500/20 text-yellow-400 border border-yellow-500/50"
  defp event_badge_class(:speciation), do: "bg-purple-500/20 text-purple-400 border border-purple-500/50"
  defp event_badge_class(_), do: "bg-gray-500/20 text-gray-400 border border-gray-500/50"

  defp event_badge_text(%{type: :champion, fitness: f}), do: "🏆 #{format_number(f)}"
  defp event_badge_text(%{type: :speciation, species: s}), do: "🧬 #{s[:name] || "New"}"
  defp event_badge_text(_), do: "Event"

  defp event_footer_class(:champion), do: "bg-yellow-500/20 text-yellow-400"
  defp event_footer_class(:speciation), do: "bg-purple-500/20 text-purple-400"
  defp event_footer_class(_), do: "bg-gray-500/20 text-gray-400"

  defp event_footer_text(%{type: :champion, fitness: f, generation: g}), do: "🏆 Gen#{g}: #{format_number(f)}"
  defp event_footer_text(%{type: :speciation, species: s}), do: "🧬 #{s[:name] || "Species"}"
  defp event_footer_text(_), do: "Event"

  defp format_number(num) when is_float(num), do: :erlang.float_to_binary(num, decimals: 1)
  defp format_number(num) when is_integer(num), do: Integer.to_string(num)
  defp format_number(_), do: "0"

  defp format_percent(nil), do: "0%"
  defp format_percent(rate) when is_float(rate), do: "#{round(rate * 100)}%"
  defp format_percent(rate) when is_integer(rate), do: "#{rate}%"
  defp format_percent(_), do: "0%"
end
