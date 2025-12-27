defmodule SwaiNodeWeb.DashboardLive do
  @moduledoc """
  Dashboard LiveView for SwaiNode.

  Shows:
  - Header with controls and training stats
  - Prominent arena canvas (live population visualization)
  - Fitness and population graphs

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

    socket =
      socket
      |> assign(:world_state, merged_state)
      |> assign(:world_stats, new_stats)
      |> assign(:behavioral_types, behavioral_types)
      |> assign(:type_history, type_history)
      |> push_event("world_update", %{agents: agents_list, food: food_maps})

    {:noreply, socket}
  end

  # ==========================================================================
  # Training Events (evolution)
  # ==========================================================================

  @impl true
  def handle_info({:generation_complete, stats}, socket) do
    # Update fitness history
    point = %{
      generation: stats.generation,
      best: stats.best_fitness,
      avg: stats.avg_fitness
    }
    fitness_history = [point | socket.assigns.fitness_history] |> Enum.take(100)

    socket =
      socket
      |> assign(:training_stats, stats)
      |> assign(:fitness_history, fitness_history)

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
      |> assign(:training_stats, %{generation: 0, best_fitness: 0.0, avg_fitness: 0.0, population: 0})

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
      |> assign(:training_stats, %{generation: 0, best_fitness: 0.0, avg_fitness: 0.0, population: 0})

    {:noreply, socket}
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
            <div class="flex items-center gap-1">
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
          </div>
        </div>
      </header>

      <!-- Main Content: Arena + Graphs -->
      <main class="flex-1 flex flex-col p-4 gap-4 min-h-0">
        <!-- Arena (prominent) -->
        <div class="flex-1 bg-gray-800 rounded-lg p-2 min-h-0 flex items-center justify-center">
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
        </div>

        <!-- Graphs Row -->
        <div class="h-32 flex gap-4 flex-shrink-0">
          <!-- Fitness Graph -->
          <div class="flex-1 bg-gray-800 rounded-lg p-3">
            <div class="flex items-center justify-between mb-2">
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
            <.fitness_graph history={@fitness_history} />
          </div>

          <!-- Population Graph by Behavioral Type -->
          <div class="flex-1 bg-gray-800 rounded-lg p-3">
            <div class="flex items-center justify-between mb-2">
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
            <.population_graph history={@type_history} />
          </div>
        </div>
      </main>
    </div>
    """
  end

  # ==========================================================================
  # Graph Components
  # ==========================================================================

  # Fitness line chart (best + avg)
  defp fitness_graph(assigns) do
    history = Enum.reverse(assigns.history)
    points_count = length(history)

    assigns =
      assigns
      |> Map.put(:reversed_history, history)
      |> Map.put(:points_count, points_count)

    ~H"""
    <div class="h-full w-full">
      <%= if @points_count > 1 do %>
        <svg viewBox="0 0 400 60" class="w-full h-full" preserveAspectRatio="none">
          <!-- Best fitness line -->
          <path
            d={build_line_path(@reversed_history, :best, @points_count)}
            fill="none"
            stroke="#eab308"
            stroke-width="2"
          />
          <!-- Avg fitness line -->
          <path
            d={build_line_path(@reversed_history, :avg, @points_count)}
            fill="none"
            stroke="#22c55e"
            stroke-width="1.5"
            stroke-dasharray="4,2"
          />
        </svg>
      <% else %>
        <div class="h-full flex items-center justify-center text-gray-500 text-sm">
          Start training to see fitness graph...
        </div>
      <% end %>
    </div>
    """
  end

  defp build_line_path(history, field, count) when count > 1 do
    max_val = history |> Enum.map(&Map.get(&1, field, 0)) |> Enum.max() |> max(1)
    width = 400
    height = 60
    step = width / max(count - 1, 1)

    points = history
    |> Enum.with_index()
    |> Enum.map(fn {point, idx} ->
      x = idx * step
      value = Map.get(point, field, 0)
      y = height - (value / max_val * height * 0.9) - 3
      "#{Float.round(x, 1)},#{Float.round(max(y, 3), 1)}"
    end)
    |> Enum.join(" L")

    "M#{points}"
  end

  defp build_line_path(_, _, _), do: ""

  # Population area chart (herbivore/omnivore/carnivore)
  defp population_graph(assigns) do
    history = Enum.reverse(assigns.history)
    points_count = length(history)

    assigns =
      assigns
      |> Map.put(:reversed_history, history)
      |> Map.put(:points_count, points_count)

    ~H"""
    <div class="h-full w-full">
      <%= if @points_count > 1 do %>
        <svg viewBox="0 0 400 60" class="w-full h-full" preserveAspectRatio="none">
          <defs>
            <linearGradient id="herbivoreGrad" x1="0%" y1="0%" x2="0%" y2="100%">
              <stop offset="0%" style="stop-color:#22c55e;stop-opacity:0.6" />
              <stop offset="100%" style="stop-color:#22c55e;stop-opacity:0.1" />
            </linearGradient>
            <linearGradient id="omnivoreGrad" x1="0%" y1="0%" x2="0%" y2="100%">
              <stop offset="0%" style="stop-color:#eab308;stop-opacity:0.6" />
              <stop offset="100%" style="stop-color:#eab308;stop-opacity:0.1" />
            </linearGradient>
            <linearGradient id="carnivoreGrad" x1="0%" y1="0%" x2="0%" y2="100%">
              <stop offset="0%" style="stop-color:#ef4444;stop-opacity:0.6" />
              <stop offset="100%" style="stop-color:#ef4444;stop-opacity:0.1" />
            </linearGradient>
          </defs>
          <!-- Stacked area chart -->
          <%= for {type, color, grad} <- [
            {:herbivore, "#22c55e", "url(#herbivoreGrad)"},
            {:omnivore, "#eab308", "url(#omnivoreGrad)"},
            {:carnivore, "#ef4444", "url(#carnivoreGrad)"}
          ] do %>
            <path
              d={build_area_path(@reversed_history, type, @points_count)}
              fill={grad}
              stroke={color}
              stroke-width="1"
            />
          <% end %>
        </svg>
      <% else %>
        <div class="h-full flex items-center justify-center text-gray-500 text-sm">
          Waiting for data...
        </div>
      <% end %>
    </div>
    """
  end

  defp build_area_path(history, type, count) when count > 1 do
    max_pop = history |> Enum.map(fn p -> p.herbivore + p.omnivore + p.carnivore end) |> Enum.max() |> max(1)
    width = 400
    height = 60
    step = width / max(count - 1, 1)

    points = history
    |> Enum.with_index()
    |> Enum.map(fn {point, idx} ->
      x = idx * step
      value = Map.get(point, type, 0)
      y = height - (value / max_pop * height * 0.9)
      {x, y}
    end)

    line_points = points |> Enum.map(fn {x, y} -> "#{Float.round(x, 1)},#{Float.round(y, 1)}" end) |> Enum.join(" L")
    "M0,#{height} L#{line_points} L#{width},#{height} Z"
  end

  defp build_area_path(_, _, _), do: ""

  defp format_number(num) when is_float(num), do: :erlang.float_to_binary(num, decimals: 1)
  defp format_number(num) when is_integer(num), do: Integer.to_string(num)
  defp format_number(_), do: "0"
end
