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

  alias SwaiNode.Simulation.WorldServer
  alias SwaiNode.Training.TrainingServer

  @pubsub SwaiNode.PubSub
  @world_topic "world:state"
  @training_topic "training:events"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(@pubsub, @world_topic)
      Phoenix.PubSub.subscribe(@pubsub, @training_topic)
    end

    # Get initial state from both servers
    world_state = WorldServer.get_state()
    world_stats = WorldServer.get_stats()
    training_stats = TrainingServer.get_stats()
    training_running = TrainingServer.running?()

    # Get geo config for world map
    geo_config = Application.get_env(:swai_node, :geo, %{})
    longitude = geo_config[:longitude] || 4.9041
    latitude = geo_config[:latitude] || 52.3676
    zoom = geo_config[:default_zoom] || 4

    socket =
      socket
      |> assign(:world_state, world_state)
      |> assign(:world_stats, world_stats)
      |> assign(:training_stats, training_stats)
      |> assign(:training_running, training_running)
      |> assign(:geo_longitude, longitude)
      |> assign(:geo_latitude, latitude)
      |> assign(:geo_zoom, zoom)
      # Population tracking
      |> assign(:behavioral_types, %{herbivore: 0, omnivore: 0, carnivore: 0})
      |> assign(:type_history, [])
      |> assign(:age_distribution, List.duplicate(0, 10))
      |> assign(:species_distribution, [])
      # Fitness tracking
      |> assign(:fitness_history, [])
      |> assign(:reward_breakdown, %{survival: 0, eating: 0, killing: 0, cooperation: 0, diplomacy: 0})
      # Culture tracking
      |> assign(:diversity_history, [])
      |> assign(:signal_distribution, List.duplicate(0, 10))
      |> assign(:social_metrics, %{cooperation_rate: 0.5, clustering: 0.0, coordination: 0.5})
      # Events
      |> assign(:events, [])
      |> assign(:champion_fitness, 0.0)
      |> assign(:audio_enabled, false)

    {:ok, socket}
  end

  # ==========================================================================
  # World Events (visualization)
  # ==========================================================================

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

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ==========================================================================
  # User Events (controls)
  # ==========================================================================

  @impl true
  def handle_event("start", _params, socket) do
    # Start world simulation
    WorldServer.play()
    WorldServer.set_mode(:realtime)

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
    WorldServer.reset()
    TrainingServer.reset()

    socket =
      socket
      |> update_world_state()
      |> assign(:training_running, false)
      |> assign(:type_history, [])
      |> assign(:diversity_history, [])
      |> assign(:fitness_history, [])
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
    world_state = WorldServer.get_state()
    stats = WorldServer.get_stats()

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
              <span class="text-gray-500">Location:</span>
              <span class="text-cyan-400 font-mono">{:erlang.float_to_binary(@geo_latitude, decimals: 2)}°, {:erlang.float_to_binary(@geo_longitude, decimals: 2)}°</span>
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

      <!-- MAIN: World Map -->
      <main class="flex-1 min-h-0" id="map-container" phx-update="ignore">
        <div
          id="world-map"
          phx-hook="WorldMap"
          data-longitude={@geo_longitude}
          data-latitude={@geo_latitude}
          data-zoom={@geo_zoom}
          data-width={@world_state.config.width}
          data-height={@world_state.config.height}
          class="w-full h-full"
        />
      </main>

      <!-- FOOTER: World Stats -->
      <footer class="bg-gray-800 border-t border-gray-700 px-4 py-2 flex-shrink-0">
        <div class="flex items-center justify-between text-sm">
          <div class="flex items-center gap-6">
            <div class="flex items-center gap-2">
              <span class="text-gray-500">Tick:</span>
              <span class="text-white font-mono">{@world_stats.tick}</span>
            </div>
            <div class="flex items-center gap-2">
              <span class="text-gray-500">Food:</span>
              <span class="text-green-400 font-mono">{@world_stats.food_count}</span>
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
