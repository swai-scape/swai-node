defmodule SwaiNodeWeb.DashboardLive do
  @moduledoc """
  Dashboard LiveView for SwaiNode.

  Shows:
  - Header with controls and training stats
  - Prominent arena canvas (live population visualization)
  - ECharts fitness and population graphs
  - Event highlighting for evolutionary milestones

  The dashboard subscribes to two event sources:
  1. `world:state` - Live visualization updates from WorldServer
  2. `training:events` - Evolution events from TrainingServer (via neuroevolution)
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

    socket =
      socket
      |> assign(:world_state, world_state)
      |> assign(:world_stats, world_stats)
      |> assign(:training_stats, training_stats)
      |> assign(:training_running, training_running)
      |> assign(:behavioral_types, %{herbivore: 0, omnivore: 0, carnivore: 0})
      |> assign(:type_history, [])
      |> assign(:fitness_history, [])
      # Event highlights
      |> assign(:events, [])
      |> assign(:champion_fitness, 0.0)
      # Audio
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

    # Track behavioral type history (last 100 points)
    tick = world_state[:tick] || 0
    type_history = update_type_history(socket.assigns.type_history, tick, behavioral_types)

    # Add events data for canvas highlighting
    events = socket.assigns.events

    socket =
      socket
      |> assign(:world_state, merged_state)
      |> assign(:world_stats, new_stats)
      |> assign(:behavioral_types, behavioral_types)
      |> assign(:type_history, type_history)
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
    # Update fitness history
    generation = stats.generation
    best = stats.best_fitness
    avg = stats.avg_fitness

    point = %{generation: generation, best: best, avg: avg}
    fitness_history = [point | socket.assigns.fitness_history] |> Enum.take(100)

    # Check for new champion (record fitness)
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
      |> assign(:events, [])
      |> assign(:champion_fitness, 0.0)
      |> assign(:training_stats, %{generation: 0, best_fitness: 0.0, avg_fitness: 0.0, population: 0})

    {:noreply, socket}
  end

  # Handle species events
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
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ==========================================================================
  # User Events (controls)
  # ==========================================================================

  # World visualization controls
  @impl true
  def handle_event("play", _params, socket) do
    WorldServer.play()
    {:noreply, update_world_state(socket)}
  end

  @impl true
  def handle_event("pause", _params, socket) do
    WorldServer.pause()
    {:noreply, update_world_state(socket)}
  end

  @impl true
  def handle_event("fast_mode", _params, socket) do
    WorldServer.set_mode(:fast)
    {:noreply, update_world_state(socket)}
  end

  @impl true
  def handle_event("realtime_mode", _params, socket) do
    WorldServer.set_mode(:realtime)
    {:noreply, update_world_state(socket)}
  end

  @impl true
  def handle_event("reset", _params, socket) do
    WorldServer.reset()
    socket = update_world_state(socket)
    socket = assign(socket, :type_history, [])
    {:noreply, socket}
  end

  # Training controls
  @impl true
  def handle_event("start_training", _params, socket) do
    TrainingServer.start_training()
    {:noreply, assign(socket, :training_running, true)}
  end

  @impl true
  def handle_event("stop_training", _params, socket) do
    TrainingServer.stop_training()
    {:noreply, assign(socket, :training_running, false)}
  end

  @impl true
  def handle_event("reset_training", _params, socket) do
    TrainingServer.reset()
    socket =
      socket
      |> assign(:training_running, false)
      |> assign(:fitness_history, [])
      |> assign(:events, [])
      |> assign(:champion_fitness, 0.0)
      |> assign(:training_stats, %{generation: 0, best_fitness: 0.0, avg_fitness: 0.0, population: 0})

    {:noreply, socket}
  end

  # Audio toggle
  @impl true
  def handle_event("toggle_audio", _params, socket) do
    new_state = not socket.assigns.audio_enabled
    socket =
      socket
      |> assign(:audio_enabled, new_state)
      |> push_event("toggle_audio", %{enabled: new_state})

    {:noreply, socket}
  end

  # ==========================================================================
  # Chart Helpers
  # ==========================================================================

  defp push_chart_update(socket) do
    fitness_options = build_fitness_chart_options(socket.assigns.fitness_history)
    population_options = build_population_chart_options(socket.assigns.type_history)

    socket
    |> push_event("update-chart-fitness-chart", %{options: fitness_options})
    |> push_event("update-chart-population-chart", %{options: population_options})
  end

  defp build_fitness_chart_options(history) do
    reversed = Enum.reverse(history)
    generations = Enum.map(reversed, & &1.generation)
    best_data = Enum.map(reversed, & &1.best)
    avg_data = Enum.map(reversed, & &1.avg)

    %{
      animation: false,
      grid: %{left: 40, right: 10, top: 10, bottom: 25},
      xAxis: %{
        type: "category",
        data: generations,
        axisLabel: %{fontSize: 10}
      },
      yAxis: %{
        type: "value",
        axisLabel: %{fontSize: 10}
      },
      tooltip: %{
        trigger: "axis"
      },
      series: [
        %{
          name: "Best",
          type: "line",
          data: best_data,
          smooth: true,
          lineStyle: %{width: 2},
          showSymbol: false,
          areaStyle: %{opacity: 0.1}
        },
        %{
          name: "Avg",
          type: "line",
          data: avg_data,
          smooth: true,
          lineStyle: %{width: 1, type: "dashed"},
          showSymbol: false
        }
      ]
    }
  end

  defp build_population_chart_options(history) do
    reversed = Enum.reverse(history)
    ticks = Enum.map(reversed, & &1.tick)
    herbivore_data = Enum.map(reversed, & &1.herbivore)
    omnivore_data = Enum.map(reversed, & &1.omnivore)
    carnivore_data = Enum.map(reversed, & &1.carnivore)

    %{
      animation: false,
      grid: %{left: 40, right: 10, top: 10, bottom: 25},
      xAxis: %{
        type: "category",
        data: ticks,
        axisLabel: %{fontSize: 10}
      },
      yAxis: %{
        type: "value",
        axisLabel: %{fontSize: 10}
      },
      tooltip: %{
        trigger: "axis"
      },
      series: [
        %{
          name: "Herbivore",
          type: "line",
          stack: "population",
          data: herbivore_data,
          smooth: true,
          showSymbol: false,
          areaStyle: %{opacity: 0.6},
          lineStyle: %{width: 1},
          itemStyle: %{color: "#22c55e"}
        },
        %{
          name: "Omnivore",
          type: "line",
          stack: "population",
          data: omnivore_data,
          smooth: true,
          showSymbol: false,
          areaStyle: %{opacity: 0.6},
          lineStyle: %{width: 1},
          itemStyle: %{color: "#eab308"}
        },
        %{
          name: "Carnivore",
          type: "line",
          stack: "population",
          data: carnivore_data,
          smooth: true,
          showSymbol: false,
          areaStyle: %{opacity: 0.6},
          lineStyle: %{width: 1},
          itemStyle: %{color: "#ef4444"}
        }
      ]
    }
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

  defp update_type_history(history, tick, types) do
    point = %{
      tick: tick,
      herbivore: types.herbivore,
      omnivore: types.omnivore,
      carnivore: types.carnivore
    }
    [point | history] |> Enum.take(100)
  end

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
      <!-- Header Bar -->
      <header class="bg-gray-800 border-b border-gray-700 px-4 py-2 flex-shrink-0">
        <div class="flex items-center justify-between">
          <!-- Left: Title + Visualization Controls -->
          <div class="flex items-center gap-4">
            <h1 class="text-lg font-bold text-purple-400">SwarmWars</h1>

            <!-- Visualization Controls -->
            <div class="flex items-center gap-1 border-r border-gray-700 pr-4">
              <span class="text-xs text-gray-500 mr-2">Arena</span>
              <button
                phx-click={if @world_state.running, do: "pause", else: "play"}
                class={["px-2 py-1 rounded text-xs font-medium transition-colors",
                  if(@world_state.running, do: "bg-yellow-600 hover:bg-yellow-500", else: "bg-green-600 hover:bg-green-500")]}
              >
                {if @world_state.running, do: "Pause", else: "Play"}
              </button>
              <button
                phx-click={if @world_state.mode == :fast, do: "realtime_mode", else: "fast_mode"}
                class={["px-2 py-1 rounded text-xs font-medium transition-colors",
                  if(@world_state.mode == :fast, do: "bg-purple-600 hover:bg-purple-500", else: "bg-gray-600 hover:bg-gray-500")]}
              >
                {if @world_state.mode == :fast, do: "Fast", else: "Normal"}
              </button>
              <button phx-click="reset" class="px-2 py-1 bg-red-600 hover:bg-red-500 rounded text-xs font-medium transition-colors">
                Reset
              </button>
            </div>

            <!-- Training Controls -->
            <div class="flex items-center gap-1 border-r border-gray-700 pr-4">
              <span class="text-xs text-gray-500 mr-2">Training</span>
              <button
                phx-click={if @training_running, do: "stop_training", else: "start_training"}
                class={["px-2 py-1 rounded text-xs font-medium transition-colors",
                  if(@training_running, do: "bg-orange-600 hover:bg-orange-500", else: "bg-blue-600 hover:bg-blue-500")]}
              >
                {if @training_running, do: "Stop", else: "Start"}
              </button>
              <button phx-click="reset_training" class="px-2 py-1 bg-gray-600 hover:bg-gray-500 rounded text-xs font-medium transition-colors">
                Reset
              </button>
            </div>

            <!-- Audio Toggle -->
            <div class="flex items-center gap-1">
              <button
                phx-click="toggle_audio"
                class={["px-2 py-1 rounded text-xs font-medium transition-colors flex items-center gap-1",
                  if(@audio_enabled, do: "bg-cyan-600 hover:bg-cyan-500", else: "bg-gray-600 hover:bg-gray-500")]}
                title={if @audio_enabled, do: "Mute agent signals", else: "Hear agent signals"}
              >
                <%= if @audio_enabled do %>
                  <svg xmlns="http://www.w3.org/2000/svg" class="h-3 w-3" viewBox="0 0 20 20" fill="currentColor">
                    <path fill-rule="evenodd" d="M9.383 3.076A1 1 0 0110 4v12a1 1 0 01-1.707.707L4.586 13H2a1 1 0 01-1-1V8a1 1 0 011-1h2.586l3.707-3.707a1 1 0 011.09-.217zM14.657 2.929a1 1 0 011.414 0A9.972 9.972 0 0119 10a9.972 9.972 0 01-2.929 7.071 1 1 0 01-1.414-1.414A7.971 7.971 0 0017 10c0-2.21-.894-4.208-2.343-5.657a1 1 0 010-1.414zm-2.829 2.828a1 1 0 011.415 0A5.983 5.983 0 0115 10a5.984 5.984 0 01-1.757 4.243 1 1 0 01-1.415-1.415A3.984 3.984 0 0013 10a3.983 3.983 0 00-1.172-2.828 1 1 0 010-1.415z" clip-rule="evenodd" />
                  </svg>
                <% else %>
                  <svg xmlns="http://www.w3.org/2000/svg" class="h-3 w-3" viewBox="0 0 20 20" fill="currentColor">
                    <path fill-rule="evenodd" d="M9.383 3.076A1 1 0 0110 4v12a1 1 0 01-1.707.707L4.586 13H2a1 1 0 01-1-1V8a1 1 0 011-1h2.586l3.707-3.707a1 1 0 011.09-.217zM12.293 7.293a1 1 0 011.414 0L15 8.586l1.293-1.293a1 1 0 111.414 1.414L16.414 10l1.293 1.293a1 1 0 01-1.414 1.414L15 11.414l-1.293 1.293a1 1 0 01-1.414-1.414L13.586 10l-1.293-1.293a1 1 0 010-1.414z" clip-rule="evenodd" />
                  </svg>
                <% end %>
                Sound
              </button>
            </div>
          </div>

          <!-- Right: Stats -->
          <div class="flex items-center gap-4 text-xs">
            <!-- Arena stats -->
            <div class="flex items-center gap-3 border-r border-gray-700 pr-4">
              <div class="flex items-center gap-1">
                <span class="text-gray-500">Tick</span>
                <span class="font-mono text-white">{@world_stats.tick}</span>
              </div>
              <div class="flex items-center gap-1">
                <span class="text-gray-500">Pop</span>
                <span class="font-mono text-cyan-400">{@world_stats.population}</span>
              </div>
              <div class="flex items-center gap-1">
                <span class="text-gray-500">Kills</span>
                <span class="font-mono text-red-400">{@world_stats.total_kills}</span>
              </div>
            </div>

            <!-- Training stats -->
            <div class="flex items-center gap-3">
              <div class="flex items-center gap-1">
                <span class="text-gray-500">Gen</span>
                <span class="font-mono text-purple-400">{@training_stats[:generation] || 0}</span>
              </div>
              <div class="flex items-center gap-1">
                <span class="text-gray-500">Best</span>
                <span class="font-mono text-yellow-400">{format_number(@training_stats[:best_fitness] || 0)}</span>
              </div>
              <div class="flex items-center gap-1">
                <span class="text-gray-500">Avg</span>
                <span class="font-mono text-green-400">{format_number(@training_stats[:avg_fitness] || 0)}</span>
              </div>
            </div>

            <!-- Event indicator -->
            <%= if length(@events) > 0 do %>
              <div class="flex items-center gap-1 pl-3 border-l border-gray-700">
                <span class="w-2 h-2 rounded-full bg-yellow-500 animate-pulse"></span>
                <span class="text-yellow-400 text-xs">{length(@events)} events</span>
              </div>
            <% end %>
          </div>
        </div>
      </header>

      <!-- Main Content: Arena + Graphs -->
      <main class="flex-1 flex flex-col p-4 gap-4 min-h-0">
        <!-- Arena (prominent) -->
        <div class="flex-1 bg-gray-800 rounded-lg p-2 min-h-0 flex items-center justify-center relative">
          <canvas
            id="world-canvas"
            phx-hook="WorldCanvas"
            data-width={@world_state.config.width}
            data-height={@world_state.config.height}
            width={@world_state.config.width}
            height={@world_state.config.height}
            class="rounded max-w-full max-h-full"
            style="image-rendering: pixelated;"
          />
          <!-- Event overlay -->
          <%= if length(@events) > 0 do %>
            <div class="absolute top-4 right-4 flex flex-col gap-1">
              <%= for event <- Enum.take(@events, 3) do %>
                <.event_badge event={event} />
              <% end %>
            </div>
          <% end %>
        </div>

        <!-- Graphs Row -->
        <div class="h-36 flex gap-4 flex-shrink-0">
          <!-- Fitness Graph (ECharts) -->
          <div class="flex-1 bg-gray-800 rounded-lg p-3">
            <div class="flex items-center justify-between mb-1">
              <h2 class="text-sm font-medium text-gray-300">Fitness (Training)</h2>
              <div class="flex items-center gap-4 text-xs">
                <div class="flex items-center gap-1">
                  <span class="w-2 h-2 rounded-full bg-yellow-500"></span>
                  <span class="text-gray-400">Best</span>
                </div>
                <div class="flex items-center gap-1">
                  <span class="w-2 h-2 rounded-full bg-green-500"></span>
                  <span class="text-gray-400">Avg</span>
                </div>
              </div>
            </div>
            <div
              id="fitness-chart"
              phx-hook="EChartsHook"
              phx-update="ignore"
              data-options={Jason.encode!(build_fitness_chart_options(@fitness_history))}
              class="h-[calc(100%-24px)] w-full"
            />
          </div>

          <!-- Population Graph (ECharts) -->
          <div class="flex-1 bg-gray-800 rounded-lg p-3">
            <div class="flex items-center justify-between mb-1">
              <h2 class="text-sm font-medium text-gray-300">Population (Arena)</h2>
              <div class="flex items-center gap-4 text-xs">
                <div class="flex items-center gap-1">
                  <span class="w-2 h-2 rounded-full bg-green-500"></span>
                  <span class="text-gray-400">Herb</span>
                  <span class="font-mono text-green-400">{@behavioral_types.herbivore}</span>
                </div>
                <div class="flex items-center gap-1">
                  <span class="w-2 h-2 rounded-full bg-yellow-500"></span>
                  <span class="text-gray-400">Omni</span>
                  <span class="font-mono text-yellow-400">{@behavioral_types.omnivore}</span>
                </div>
                <div class="flex items-center gap-1">
                  <span class="w-2 h-2 rounded-full bg-red-500"></span>
                  <span class="text-gray-400">Carn</span>
                  <span class="font-mono text-red-400">{@behavioral_types.carnivore}</span>
                </div>
              </div>
            </div>
            <div
              id="population-chart"
              phx-hook="EChartsHook"
              phx-update="ignore"
              data-options={Jason.encode!(build_population_chart_options(@type_history))}
              class="h-[calc(100%-24px)] w-full"
            />
          </div>
        </div>
      </main>
    </div>
    """
  end

  # ==========================================================================
  # Components
  # ==========================================================================

  defp event_badge(assigns) do
    ~H"""
    <div class={[
      "px-2 py-1 rounded text-xs font-medium animate-fade-in",
      event_badge_class(@event.type)
    ]}>
      {event_badge_text(@event)}
    </div>
    """
  end

  defp event_badge_class(:champion), do: "bg-yellow-500/20 text-yellow-400 border border-yellow-500/50"
  defp event_badge_class(:speciation), do: "bg-purple-500/20 text-purple-400 border border-purple-500/50"
  defp event_badge_class(_), do: "bg-gray-500/20 text-gray-400 border border-gray-500/50"

  defp event_badge_text(%{type: :champion, fitness: f, generation: g}) do
    "Champion! Gen #{g}: #{format_number(f)}"
  end
  defp event_badge_text(%{type: :speciation, species: s}) do
    "New Species: #{s[:name] || "Unknown"}"
  end
  defp event_badge_text(_), do: "Event"

  defp format_number(num) when is_float(num), do: :erlang.float_to_binary(num, decimals: 1)
  defp format_number(num) when is_integer(num), do: Integer.to_string(num)
  defp format_number(_), do: "0"
end
