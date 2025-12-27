defmodule SwaiNodeWeb.DashboardLive do
  @moduledoc """
  Dashboard LiveView for SwaiNode.

  Shows:
  - Real-time world visualization (canvas)
  - Population statistics
  - LC silo status and event stream
  - AI insights panel
  """

  use SwaiNodeWeb, :live_view

  alias SwaiNode.Simulation.{WorldServer, LCStatus, LCEventBridge}

  @pubsub SwaiNode.PubSub
  @topic "world:state"
  @lc_topic "lc:silo:updates"
  @lc_events_topic "lc:silo:events"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(@pubsub, @topic)
      Phoenix.PubSub.subscribe(@pubsub, @lc_topic)
      Phoenix.PubSub.subscribe(@pubsub, @lc_events_topic)
    end

    # Get initial state
    world_state = WorldServer.get_state()
    stats = WorldServer.get_stats()
    mesh_status = get_mesh_status()
    lc_status = LCStatus.dashboard_summary()
    lc_events = get_lc_events()

    socket =
      socket
      |> assign(:world_state, world_state)
      |> assign(:stats, stats)
      |> assign(:mesh_status, mesh_status)
      |> assign(:lc_status, lc_status)
      |> assign(:lc_events, lc_events)
      |> assign(:top_agents, get_top_agents(world_state.agents))
      |> assign(:insights, generate_insights(stats, lc_status))
      # Evolution history tracking (last 50 data points)
      |> assign(:fitness_history, [])
      |> assign(:population_history, [])
      # Species tracking
      |> assign(:species, [])
      |> assign(:diversity, 0.0)

    {:ok, socket}
  end

  # Handle LC silo update events (event-driven)
  @impl true
  def handle_info({:lc_update, silos}, socket) do
    lc_status = build_lc_status_from_event(silos, socket.assigns.lc_status)
    insights = generate_insights(socket.assigns.stats, lc_status)
    socket = socket
             |> assign(:lc_status, lc_status)
             |> assign(:insights, insights)
    {:noreply, socket}
  end

  # Handle individual LC events for the event stream
  @impl true
  def handle_info({:lc_event, event}, socket) do
    events = [event | socket.assigns.lc_events] |> Enum.take(20)
    {:noreply, assign(socket, :lc_events, events)}
  end

  @impl true
  def handle_info({:world_update, world_state}, socket) do
    # Merge broadcast state with existing state to preserve config
    existing = socket.assigns.world_state
    merged_state = Map.merge(existing, world_state)

    # Convert food tuples to maps for JSON encoding
    food_maps = convert_food_to_maps(world_state[:food] || [])

    # Get agents list (ensure it's a list)
    agents_list = world_state[:agents] || []

    # Update stats from broadcast
    new_stats = build_stats_from_broadcast(world_state, socket.assigns.stats)

    # Track evolution history (sample every update, keep last 50 points)
    tick = world_state[:tick] || 0
    {fitness_history, population_history} = update_history(
      socket.assigns.fitness_history,
      socket.assigns.population_history,
      tick,
      new_stats.best_fitness,
      new_stats.population
    )

    # Extract species data
    species = world_state[:species] || socket.assigns.species
    diversity = world_state[:diversity] || socket.assigns.diversity

    socket =
      socket
      |> assign(:world_state, merged_state)
      |> assign(:stats, new_stats)
      |> assign(:top_agents, get_top_agents(agents_list))
      |> assign(:insights, generate_insights(new_stats, socket.assigns.lc_status))
      |> assign(:fitness_history, fitness_history)
      |> assign(:population_history, population_history)
      |> assign(:species, species)
      |> assign(:diversity, diversity)
      |> push_event("world_update", %{
        agents: agents_list,
        food: food_maps
      })

    {:noreply, socket}
  end

  # Safely convert food tuples to maps
  defp convert_food_to_maps(food) when is_list(food) do
    Enum.map(food, fn
      {x, y, energy} -> %{x: x, y: y, energy: energy}
      %{x: _, y: _, energy: _} = map -> map
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end
  defp convert_food_to_maps(_), do: []

  # Sample history on each broadcast, keep last 60 points
  defp update_history(fitness_history, population_history, tick, best_fitness, population) do
    # Record on each broadcast (already throttled by WorldServer)
    point = %{tick: tick, fitness: best_fitness, population: population}
    new_fitness = [point | fitness_history] |> Enum.take(60)
    new_pop = [point | population_history] |> Enum.take(60)
    {new_fitness, new_pop}
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
      total_food_eaten: broadcast_stats[:food_eaten] || existing_stats[:total_food_eaten] || 0,
      total_attacks: broadcast_stats[:attacks] || existing_stats[:total_attacks] || 0,
      total_kills: broadcast_stats[:kills] || existing_stats[:total_kills] || 0,
      food_count: length(world_state[:food] || [])
    }
  end

  @impl true
  def handle_event("play", _params, socket) do
    WorldServer.play()
    {:noreply, update_state(socket)}
  end

  @impl true
  def handle_event("pause", _params, socket) do
    WorldServer.pause()
    {:noreply, update_state(socket)}
  end

  @impl true
  def handle_event("fast_mode", _params, socket) do
    WorldServer.set_mode(:fast)
    {:noreply, update_state(socket)}
  end

  @impl true
  def handle_event("realtime_mode", _params, socket) do
    WorldServer.set_mode(:realtime)
    {:noreply, update_state(socket)}
  end

  @impl true
  def handle_event("reset", _params, socket) do
    WorldServer.reset()
    {:noreply, update_state(socket)}
  end

  defp update_state(socket) do
    world_state = WorldServer.get_state()
    stats = WorldServer.get_stats()

    socket
    |> assign(:world_state, world_state)
    |> assign(:stats, stats)
    |> assign(:top_agents, get_top_agents(world_state.agents))
  end

  defp get_top_agents(agents) when is_list(agents) do
    agents
    |> Enum.sort_by(& &1.fitness, :desc)
    |> Enum.take(5)
  end

  defp get_top_agents(_), do: []

  defp get_lc_events do
    try do
      LCEventBridge.get_events() |> Enum.take(20)
    catch
      _, _ -> []
    end
  end

  defp generate_insights(stats, lc_status) do
    insights = []

    # Population insight
    insights = add_population_insight(insights, stats)

    # Stagnation insight
    insights = add_stagnation_insight(insights, lc_status)

    # Silo insight
    insights = add_silo_insight(insights, lc_status)

    # Fitness insight
    insights = add_fitness_insight(insights, stats)

    # Limit to 4 insights
    Enum.take(insights, 4)
  end

  defp add_population_insight(insights, stats) do
    cond do
      stats.population < 20 ->
        [%{type: :critical, icon: "⚠", message: "Population critically low (#{stats.population}). Consider reset."} | insights]
      stats.population > 200 ->
        [%{type: :warning, icon: "📈", message: "Population high (#{stats.population}). Food pressure increasing."} | insights]
      true ->
        insights
    end
  end

  defp add_stagnation_insight(insights, lc_status) do
    severity = lc_status[:stagnation_severity] || 0.0
    cond do
      severity > 0.7 ->
        [%{type: :action, icon: "🧬", message: "High stagnation - mutation rate increased to escape local optima."} | insights]
      severity > 0.4 ->
        [%{type: :warning, icon: "⏸", message: "Mild stagnation detected. LC adjusting parameters."} | insights]
      true ->
        insights
    end
  end

  defp add_silo_insight(insights, lc_status) do
    enabled = lc_status[:enabled] || 2
    total = lc_status[:total] || 13
    cond do
      enabled == total ->
        [%{type: :success, icon: "✓", message: "All #{total} LC silos active. Full adaptive control."} | insights]
      enabled < 5 ->
        [%{type: :info, icon: "ℹ", message: "#{enabled}/#{total} silos active. Enable more for richer adaptation."} | insights]
      true ->
        insights
    end
  end

  defp add_fitness_insight(insights, stats) do
    cond do
      stats.best_fitness > 5000 ->
        [%{type: :success, icon: "🏆", message: "Champion fitness #{format_number(stats.best_fitness)}! Strong emergence."} | insights]
      stats.avg_fitness < 100 and stats.tick > 1000 ->
        [%{type: :warning, icon: "📉", message: "Low average fitness. Population may need more diversity."} | insights]
      true ->
        insights
    end
  end

  defp build_lc_status_from_event(silos, existing_status) when is_map(silos) do
    # Convert event bridge format to dashboard format
    silo_list = Enum.map(silos, fn {type, data} ->
      %{
        type: type,
        name: type |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize(),
        description: silo_description(type),
        time_constant: silo_time_constant(type),
        enabled: Map.get(data, :enabled, false),
        core: type in [:task, :resource],
        status: if(Map.get(data, :enabled, false), do: :running, else: :not_running),
        mutation_rate: get_in(data, [:recommendations, :mutation_rate]),
        mutation_strength: get_in(data, [:recommendations, :mutation_strength]),
        stagnation_severity: get_in(data, [:signals, :stagnation_severity]),
        concurrency: get_in(data, [:signals, :current_concurrency])
      }
    end)

    enabled_count = Enum.count(silo_list, & &1.enabled)
    task_silo = Enum.find(silo_list, &(&1.type == :task))

    %{
      total: length(silo_list),
      enabled: enabled_count,
      core: 2,
      extension: enabled_count - 2,
      silos: silo_list,
      stagnation_severity: task_silo[:stagnation_severity] || existing_status[:stagnation_severity] || 0.0,
      velocity: existing_status[:velocity] || 0.0
    }
  end

  defp build_lc_status_from_event(_, existing_status), do: existing_status

  defp silo_description(:task), do: "Evolution Optimization"
  defp silo_description(:resource), do: "System Stability"
  defp silo_description(:temporal), do: "Episode Timing"
  defp silo_description(:competitive), do: "Opponent Archives"
  defp silo_description(:social), do: "Reputation & Coalitions"
  defp silo_description(:cultural), do: "Innovations & Traditions"
  defp silo_description(:ecological), do: "Niches & Stress"
  defp silo_description(:morphological), do: "Network Complexity"
  defp silo_description(:developmental), do: "Ontogeny & Plasticity"
  defp silo_description(:regulatory), do: "Gene Expression"
  defp silo_description(:economic), do: "Compute Budgets"
  defp silo_description(:communication), do: "Vocabulary Evolution"
  defp silo_description(:distribution), do: "Mesh Networking"
  defp silo_description(_), do: ""

  defp silo_time_constant(:task), do: 50
  defp silo_time_constant(:resource), do: 5
  defp silo_time_constant(:temporal), do: 10
  defp silo_time_constant(:competitive), do: 50
  defp silo_time_constant(:social), do: 50
  defp silo_time_constant(:cultural), do: 100
  defp silo_time_constant(:ecological), do: 100
  defp silo_time_constant(:morphological), do: 30
  defp silo_time_constant(:developmental), do: 100
  defp silo_time_constant(:regulatory), do: 50
  defp silo_time_constant(:economic), do: 20
  defp silo_time_constant(:communication), do: 30
  defp silo_time_constant(:distribution), do: 1
  defp silo_time_constant(_), do: 0

  defp get_mesh_status do
    try do
      SwaiNode.MeshClient.status()
    rescue
      _ -> %{connected: false, standalone_mode: true, node_id: nil, realm: nil}
    catch
      :exit, _ -> %{connected: false, standalone_mode: true, node_id: nil, realm: nil}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen bg-gray-900 text-white flex flex-col overflow-hidden">
      <!-- Compact Header -->
      <header class="bg-gray-800/80 border-b border-gray-700/50 px-2 py-1 flex-shrink-0">
        <div class="flex items-center justify-between">
          <!-- Left: Title + Controls -->
          <div class="flex items-center gap-2">
            <h1 class="text-sm font-bold text-purple-400">SwarmWars</h1>
            <div class="flex items-center gap-0.5">
              <button
                phx-click={if @world_state.running, do: "pause", else: "play"}
                class={["px-1 py-0.5 rounded text-[10px] font-medium", if(@world_state.running, do: "bg-yellow-600/80", else: "bg-green-600/80")]}
              >
                {if @world_state.running, do: "⏸", else: "▶"}
              </button>
              <button
                phx-click={if @world_state.mode == :fast, do: "realtime_mode", else: "fast_mode"}
                class={["px-1 py-0.5 rounded text-[10px] font-medium", if(@world_state.mode == :fast, do: "bg-purple-600/80", else: "bg-gray-600/80")]}
              >
                {if @world_state.mode == :fast, do: "⚡", else: "🐢"}
              </button>
              <button phx-click="reset" class="px-1 py-0.5 bg-red-600/60 rounded text-[10px]">↻</button>
            </div>
          </div>

          <!-- Center: Minimal Stats -->
          <div class="flex items-center gap-2 text-[10px] text-gray-400">
            <span>Tick <span class="text-gray-300 font-mono">{@stats.tick}</span></span>
          </div>

          <!-- Right: Status -->
          <.connection_badge connected={@mesh_status.connected} standalone={@mesh_status[:standalone_mode] || false} />
        </div>
      </header>

      <!-- 4x4 Grid Layout -->
      <main class="flex-1 grid grid-cols-4 grid-rows-4 gap-1 p-1 min-h-0">
        <!-- Arena: spans columns 1-2, rows 1-2 -->
        <div class="col-span-2 row-span-2 bg-gray-800/50 rounded p-1 flex flex-col min-h-0">
          <canvas
            id="world-canvas"
            phx-hook="WorldCanvas"
            data-width={@world_state.config.width}
            data-height={@world_state.config.height}
            width={@world_state.config.width}
            height={@world_state.config.height}
            class="rounded flex-1 w-full h-full object-contain"
          />
        </div>

        <!-- Stats Panel: column 3, row 1 -->
        <div class="bg-gray-800/50 rounded p-1.5 flex flex-col min-h-0">
          <.stats_mini stats={@stats} />
        </div>

        <!-- Population Graph: column 4, row 1 -->
        <div class="bg-gray-800/50 rounded p-1.5 flex flex-col min-h-0">
          <.population_mini population_history={@population_history} stats={@stats} />
        </div>

        <!-- Fitness Graph: column 3, row 2 -->
        <div class="bg-gray-800/50 rounded p-1.5 flex flex-col min-h-0">
          <.fitness_mini fitness_history={@fitness_history} stats={@stats} />
        </div>

        <!-- Top Agents: column 4, row 2 -->
        <div class="bg-gray-800/50 rounded p-1.5 flex flex-col min-h-0 overflow-hidden">
          <.top_agents_mini top_agents={@top_agents} />
        </div>

        <!-- LC Panel: spans all 4 columns, row 3 -->
        <div class="col-span-4 bg-gray-800/50 rounded p-1.5 min-h-0 overflow-hidden">
          <.lc_row lc_status={@lc_status} />
        </div>

        <!-- Events: spans columns 1-2, row 4 -->
        <div class="col-span-2 bg-gray-800/50 rounded p-1.5 min-h-0 overflow-hidden">
          <.events_mini events={@lc_events} />
        </div>

        <!-- Insights: column 3, row 4 -->
        <div class="bg-gray-800/50 rounded p-1.5 min-h-0 overflow-hidden">
          <.insights_mini insights={@insights} />
        </div>

        <!-- Species: column 4, row 4 -->
        <div class="bg-gray-800/50 rounded p-1.5 min-h-0 overflow-hidden">
          <.species_mini species={@species} diversity={@diversity} />
        </div>
      </main>
    </div>
    """
  end

  # =============================================================================
  # Components
  # =============================================================================

  defp connection_badge(assigns) do
    ~H"""
    <div class={[
      "flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs",
      cond do
        @connected -> "bg-green-900/50 text-green-400"
        @standalone -> "bg-yellow-900/50 text-yellow-400"
        true -> "bg-red-900/50 text-red-400"
      end
    ]}>
      <span class={[
        "w-1.5 h-1.5 rounded-full",
        cond do
          @connected -> "bg-green-400 animate-pulse"
          @standalone -> "bg-yellow-400"
          true -> "bg-red-400"
        end
      ]}></span>
      <span>{cond do
        @connected -> "Online"
        @standalone -> "Solo"
        true -> "Off"
      end}</span>
    </div>
    """
  end

  # =============================================================================
  # Mini Components for 4x4 Grid
  # =============================================================================

  # Stats Mini - compact stats for single cell
  defp stats_mini(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <div class="text-[8px] text-gray-500 mb-1">Stats</div>
      <div class="flex-1 grid grid-cols-2 gap-1 text-[9px]">
        <div class="bg-gray-700/30 rounded px-1 py-0.5 text-center">
          <div class="text-[7px] text-gray-500">Pop</div>
          <div class="font-mono text-white">{@stats.population}</div>
        </div>
        <div class="bg-gray-700/30 rounded px-1 py-0.5 text-center">
          <div class="text-[7px] text-gray-500">Gen</div>
          <div class="font-mono text-purple-400">{@stats.generation}</div>
        </div>
        <div class="bg-gray-700/30 rounded px-1 py-0.5 text-center">
          <div class="text-[7px] text-gray-500">Births</div>
          <div class="font-mono text-emerald-400">{@stats.total_births}</div>
        </div>
        <div class="bg-gray-700/30 rounded px-1 py-0.5 text-center">
          <div class="text-[7px] text-gray-500">Deaths</div>
          <div class="font-mono text-red-400">{@stats.total_deaths}</div>
        </div>
        <div class="bg-gray-700/30 rounded px-1 py-0.5 text-center">
          <div class="text-[7px] text-gray-500">Kills</div>
          <div class="font-mono text-orange-400">{@stats.total_kills}</div>
        </div>
      </div>
    </div>
    """
  end

  # Population Mini - small graph
  defp population_mini(assigns) do
    population_data = Enum.reverse(assigns.population_history)
    assigns = assign(assigns, :population_data, population_data)

    ~H"""
    <div class="h-full flex flex-col">
      <div class="flex items-center justify-between mb-1">
        <span class="text-[8px] text-gray-500">Population</span>
        <span class="text-[9px] font-mono text-blue-400">{@stats.population}</span>
      </div>
      <div class="flex-1 min-h-0">
        <.mini_graph data={@population_data} color="blue" value_key={:population} />
      </div>
    </div>
    """
  end

  # Fitness Mini - small graph
  defp fitness_mini(assigns) do
    fitness_data = Enum.reverse(assigns.fitness_history)
    assigns = assign(assigns, :fitness_data, fitness_data)

    ~H"""
    <div class="h-full flex flex-col">
      <div class="flex items-center justify-between mb-1">
        <span class="text-[8px] text-gray-500">Best Fit</span>
        <span class="text-[9px] font-mono text-green-400">{format_number(@stats.best_fitness)}</span>
      </div>
      <div class="flex-1 min-h-0">
        <.mini_graph data={@fitness_data} color="green" value_key={:fitness} />
      </div>
    </div>
    """
  end

  # Top Agents Mini - compact list
  defp top_agents_mini(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <div class="text-[8px] text-gray-500 mb-1">Champions</div>
      <div class="flex-1 space-y-0.5 overflow-hidden">
        <%= for {agent, idx} <- Enum.with_index(@top_agents) |> Enum.take(4) do %>
          <div class="flex items-center gap-1 text-[8px]">
            <span class={[
              "w-3 text-center font-mono",
              if(idx == 0, do: "text-yellow-400", else: "text-gray-500")
            ]}>{idx + 1}</span>
            <span class="text-gray-400 truncate">g{agent.generation}</span>
            <span class="font-mono text-purple-400 ml-auto">{format_number(agent.fitness)}</span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # LC Row - horizontal silo display
  defp lc_row(assigns) do
    severity = assigns.lc_status[:stagnation_severity] || 0.0
    sorted_silos = Enum.sort_by(assigns.lc_status.silos, fn silo ->
      {not silo.core, silo.type}
    end)

    assigns = assigns
              |> assign(:sorted_silos, sorted_silos)
              |> assign(:severity, severity)

    ~H"""
    <div class="h-full flex flex-col">
      <div class="flex items-center justify-between mb-1">
        <span class="text-[8px] text-gray-500">Liquid Conglomerate</span>
        <div class="flex items-center gap-1">
          <div class="w-12 h-1.5 bg-gray-700 rounded-full overflow-hidden">
            <div class={[
              "h-full rounded-full",
              cond do
                @severity < 0.2 -> "bg-emerald-500"
                @severity < 0.5 -> "bg-yellow-500"
                @severity < 0.8 -> "bg-orange-500"
                true -> "bg-red-500"
              end
            ]} style={"width: #{round(@severity * 100)}%"}></div>
          </div>
          <span class="text-[8px] font-mono text-gray-400">{round(@severity * 100)}%</span>
        </div>
      </div>
      <div class="flex-1 flex gap-0.5 overflow-x-auto">
        <%= for silo <- @sorted_silos do %>
          <.silo_mini silo={silo} />
        <% end %>
      </div>
    </div>
    """
  end

  # Silo Mini - tiny silo indicator
  defp silo_mini(assigns) do
    silo = assigns.silo
    color_class = silo_color_class(silo.type)

    assigns = assigns
              |> assign(:color_class, color_class)

    ~H"""
    <div class={[
      "flex-shrink-0 w-10 rounded p-0.5 text-center",
      if(@silo.enabled, do: @color_class.bg, else: "bg-gray-800/30 opacity-40"),
      if(@silo.enabled, do: @color_class.border, else: "border-gray-700/20"),
      "border"
    ]}>
      <div class={[
        "text-[7px] font-medium truncate",
        if(@silo.enabled, do: @color_class.text, else: "text-gray-600")
      ]}>{silo_abbrev(@silo.type)}</div>
      <div class="text-[6px] text-gray-500 font-mono">τ{Map.get(@silo, :time_constant, 0)}</div>
    </div>
    """
  end

  defp silo_abbrev(:task), do: "TSK"
  defp silo_abbrev(:resource), do: "RSC"
  defp silo_abbrev(:temporal), do: "TMP"
  defp silo_abbrev(:competitive), do: "CMP"
  defp silo_abbrev(:social), do: "SOC"
  defp silo_abbrev(:cultural), do: "CUL"
  defp silo_abbrev(:ecological), do: "ECO"
  defp silo_abbrev(:morphological), do: "MOR"
  defp silo_abbrev(:developmental), do: "DEV"
  defp silo_abbrev(:regulatory), do: "REG"
  defp silo_abbrev(:economic), do: "ECN"
  defp silo_abbrev(:communication), do: "COM"
  defp silo_abbrev(:distribution), do: "DST"
  defp silo_abbrev(type), do: type |> Atom.to_string() |> String.slice(0..2) |> String.upcase()

  # Events Mini - compact event list
  defp events_mini(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <div class="flex items-center justify-between mb-1">
        <span class="text-[8px] text-gray-500">Events</span>
        <span class="text-[7px] text-gray-600">{length(@events)}</span>
      </div>
      <div class="flex-1 space-y-0.5 overflow-hidden">
        <%= if @events == [] do %>
          <div class="text-[8px] text-gray-600 text-center py-2">Waiting...</div>
        <% else %>
          <%= for event <- Enum.take(@events, 5) do %>
            <div class="flex items-center gap-1 text-[8px] bg-gray-700/20 rounded px-1 py-0.5">
              <span class={["w-1 h-1 rounded-full flex-shrink-0", event_color(event.type)]}></span>
              <span class="text-gray-500 font-mono">{event.silo}</span>
              <span class="text-gray-400 truncate flex-1">{String.slice(event.message, 0..25)}</span>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # Insights Mini - compact insights
  defp insights_mini(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <div class="text-[8px] text-gray-500 mb-1">AI</div>
      <div class="flex-1 space-y-0.5 overflow-hidden">
        <%= if @insights == [] do %>
          <div class="text-[8px] text-emerald-400 text-center py-1">✓ OK</div>
        <% else %>
          <%= for insight <- Enum.take(@insights, 3) do %>
            <div class={["text-[7px] rounded px-1 py-0.5", insight_bg(insight.type)]}>
              <span>{insight.icon}</span>
              <span class={insight_text(insight.type)}>{String.slice(insight.message, 0..30)}</span>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # Species Mini - species distribution with diversity index
  defp species_mini(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <div class="flex items-center justify-between mb-1">
        <span class="text-[8px] text-gray-500">Species</span>
        <span class="text-[7px] font-mono text-cyan-400" title="Diversity Index">{Float.round(@diversity * 100, 0)}%</span>
      </div>
      <div class="flex-1 overflow-hidden">
        <%= if @species == [] do %>
          <div class="text-[8px] text-gray-600 text-center py-2">Clustering...</div>
        <% else %>
          <div class="space-y-0.5">
            <%= for sp <- Enum.take(@species, 5) do %>
              <div class="flex items-center gap-1 text-[8px]">
                <span
                  class="w-2 h-2 rounded-full flex-shrink-0"
                  style={"background-color: hsl(#{sp.color_hue}, 70%, 50%)"}
                ></span>
                <span class="text-gray-500 font-mono truncate">{sp.id}</span>
                <span class="text-gray-400 ml-auto">{sp.percentage}%</span>
              </div>
            <% end %>
          </div>
          <div class="mt-1 text-[7px] text-gray-600 text-center">
            {length(@species)} total species
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # =============================================================================
  # Legacy Components (kept for reference but unused in 4x4 layout)
  # =============================================================================

  # Stats Compact - for 4-quadrant layout
  defp stats_compact(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-1.5">
        <span class="text-[10px] font-medium text-gray-400">Statistics</span>
        <span class="text-[9px] text-gray-500">{length(@top_agents)} champions</span>
      </div>

      <div class="grid grid-cols-4 gap-1.5 text-[10px]">
        <div class="bg-gray-700/30 rounded px-2 py-1 text-center">
          <div class="text-gray-500 text-[8px]">Food</div>
          <div class="font-mono text-green-400">{@stats.food_count}</div>
        </div>
        <div class="bg-gray-700/30 rounded px-2 py-1 text-center">
          <div class="text-gray-500 text-[8px]">Avg Fit</div>
          <div class="font-mono text-gray-300">{format_number(@stats.avg_fitness)}</div>
        </div>
        <div class="bg-gray-700/30 rounded px-2 py-1 text-center">
          <div class="text-gray-500 text-[8px]">Births</div>
          <div class="font-mono text-emerald-400">{@stats.total_births}</div>
        </div>
        <div class="bg-gray-700/30 rounded px-2 py-1 text-center">
          <div class="text-gray-500 text-[8px]">Deaths</div>
          <div class="font-mono text-red-400">{@stats.total_deaths}</div>
        </div>
        <div class="bg-gray-700/30 rounded px-2 py-1 text-center">
          <div class="text-gray-500 text-[8px]">Kills</div>
          <div class="font-mono text-orange-400">{@stats.total_kills}</div>
        </div>
      </div>

      <!-- Top Agents Row -->
      <div class="mt-1.5 bg-gray-700/30 rounded px-2 py-1">
        <div class="text-gray-500 text-[8px] mb-0.5">Top Agents</div>
        <div class="flex gap-2 flex-wrap">
          <%= for {agent, idx} <- Enum.with_index(@top_agents) |> Enum.take(5) do %>
            <span class={["text-[9px] font-mono", if(idx == 0, do: "text-yellow-400", else: "text-purple-400")]}>
              {format_number(agent.fitness)}
            </span>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # Evolution Graphs - Fitness and Population over time
  defp evolution_graphs(assigns) do
    # Reverse history so oldest is first (for SVG path left-to-right)
    fitness_data = Enum.reverse(assigns.fitness_history)
    population_data = Enum.reverse(assigns.population_history)

    assigns = assigns
              |> assign(:fitness_data, fitness_data)
              |> assign(:population_data, population_data)

    ~H"""
    <div class="bg-gray-800/50 rounded-lg p-3 border border-gray-700/30">
      <div class="flex items-center justify-between mb-2">
        <span class="text-xs font-medium text-gray-400">Evolution Progress</span>
        <span class="text-[10px] text-gray-500">Gen {@stats.generation}</span>
      </div>

      <div class="grid grid-cols-2 gap-2">
        <!-- Fitness Graph -->
        <div class="bg-gray-900/50 rounded p-2">
          <div class="flex items-center justify-between mb-1">
            <span class="text-[9px] text-gray-500">Best Fitness</span>
            <span class="text-[10px] font-mono text-green-400">{format_number(@stats.best_fitness)}</span>
          </div>
          <.mini_graph data={@fitness_data} color="green" value_key={:fitness} />
        </div>

        <!-- Population Graph -->
        <div class="bg-gray-900/50 rounded p-2">
          <div class="flex items-center justify-between mb-1">
            <span class="text-[9px] text-gray-500">Population</span>
            <span class="text-[10px] font-mono text-blue-400">{@stats.population}</span>
          </div>
          <.mini_graph data={@population_data} color="blue" value_key={:population} />
        </div>
      </div>
    </div>
    """
  end

  # Mini SVG sparkline graph
  defp mini_graph(assigns) do
    data = assigns.data
    value_key = assigns.value_key
    color = assigns.color

    # Extract values
    values = Enum.map(data, fn point -> Map.get(point, value_key, 0) end)

    # Calculate SVG path
    {path, _max_val} = build_sparkline_path(values, 100, 24)

    # Color mapping
    stroke_color = case color do
      "green" -> "#22c55e"
      "blue" -> "#3b82f6"
      "purple" -> "#a855f7"
      _ -> "#9ca3af"
    end

    fill_color = case color do
      "green" -> "rgba(34, 197, 94, 0.1)"
      "blue" -> "rgba(59, 130, 246, 0.1)"
      "purple" -> "rgba(168, 85, 247, 0.1)"
      _ -> "rgba(156, 163, 175, 0.1)"
    end

    assigns = assigns
              |> assign(:path, path)
              |> assign(:stroke_color, stroke_color)
              |> assign(:fill_color, fill_color)
              |> assign(:has_data, length(values) > 1)

    ~H"""
    <div class="h-6 w-full">
      <%= if @has_data do %>
        <svg viewBox="0 0 100 24" class="w-full h-full" preserveAspectRatio="none">
          <!-- Area fill -->
          <path d={@path <> " L 100 24 L 0 24 Z"} fill={@fill_color} />
          <!-- Line -->
          <path d={@path} fill="none" stroke={@stroke_color} stroke-width="1.5" />
        </svg>
      <% else %>
        <div class="h-full flex items-center justify-center text-[8px] text-gray-600">
          Collecting data...
        </div>
      <% end %>
    </div>
    """
  end

  # Build SVG path from values
  defp build_sparkline_path([], _width, _height), do: {"M 0 12", 1}
  defp build_sparkline_path([single], _width, height), do: {"M 0 #{height / 2} L 100 #{height / 2}", single}
  defp build_sparkline_path(values, width, height) do
    max_val = Enum.max(values) |> max(1)
    min_val = Enum.min(values) |> min(0)
    range = max(max_val - min_val, 1)

    points = values
             |> Enum.with_index()
             |> Enum.map(fn {val, idx} ->
               x = idx / (length(values) - 1) * width
               y = height - ((val - min_val) / range * (height - 2) + 1)
               {x, y}
             end)

    path = points
           |> Enum.with_index()
           |> Enum.map(fn {{x, y}, idx} ->
             if idx == 0, do: "M #{x} #{y}", else: "L #{x} #{y}"
           end)
           |> Enum.join(" ")

    {path, max_val}
  end

  # LC Panel - All 13 Silos with Temporal Dynamics
  defp lc_compact(assigns) do
    severity = assigns.lc_status[:stagnation_severity] || 0.0
    enabled_count = assigns.lc_status[:enabled] || 0
    total_count = assigns.lc_status[:total] || 13

    # Sort silos: core first, then extensions
    sorted_silos = Enum.sort_by(assigns.lc_status.silos, fn silo ->
      {not silo.core, silo.type}
    end)

    assigns = assigns
              |> assign(:sorted_silos, sorted_silos)
              |> assign(:enabled_count, enabled_count)
              |> assign(:total_count, total_count)
              |> assign(:severity, severity)

    ~H"""
    <div class="bg-gray-800/50 rounded-lg p-3 border border-gray-700/30">
      <!-- Header with stagnation meter -->
      <div class="flex items-center justify-between mb-3">
        <div class="flex items-center gap-2">
          <span class="text-xs font-medium text-gray-400">Liquid Conglomerate</span>
          <span class="text-[10px] px-1.5 py-0.5 rounded bg-purple-900/30 text-purple-400">
            {@enabled_count}/{@total_count} silos
          </span>
        </div>
        <div class="flex items-center gap-2">
          <span class="text-[10px] text-gray-500">Stagnation</span>
          <div class="w-16 h-2 bg-gray-700 rounded-full overflow-hidden">
            <div class={[
              "h-full rounded-full transition-all duration-300",
              cond do
                @severity < 0.2 -> "bg-emerald-500"
                @severity < 0.5 -> "bg-yellow-500"
                @severity < 0.8 -> "bg-orange-500"
                true -> "bg-red-500 animate-pulse"
              end
            ]} style={"width: #{round(@severity * 100)}%"}></div>
          </div>
          <span class="text-[10px] font-mono text-gray-400">{round(@severity * 100)}%</span>
        </div>
      </div>

      <!-- All 13 Silos Grid -->
      <div class="grid grid-cols-4 gap-1.5">
        <%= for silo <- @sorted_silos do %>
          <.silo_card silo={silo} />
        <% end %>
      </div>
    </div>
    """
  end

  # Individual silo card with temporal dynamics
  defp silo_card(assigns) do
    silo = assigns.silo
    tau = Map.get(silo, :time_constant, 0)

    # Extract signal values safely
    mutation_rate = Map.get(silo, :mutation_rate)
    stagnation = Map.get(silo, :stagnation_severity)
    memory_pressure = Map.get(silo, :memory_pressure)
    cpu_pressure = Map.get(silo, :cpu_pressure)

    # Determine activity level from signals
    activity = cond do
      mutation_rate != nil -> :high
      stagnation != nil and stagnation > 0.3 -> :medium
      memory_pressure != nil or cpu_pressure != nil -> :low
      silo.enabled -> :low
      true -> :inactive
    end

    # Determine signal display - pick most relevant metric
    signal_display = cond do
      mutation_rate != nil -> {:mutation, round(mutation_rate * 100)}
      stagnation != nil and stagnation > 0 -> {:stagnation, round(stagnation * 100)}
      memory_pressure != nil and memory_pressure > 0 -> {:memory, round(memory_pressure * 100)}
      cpu_pressure != nil and cpu_pressure > 0 -> {:cpu, round(cpu_pressure * 100)}
      true -> nil
    end

    # Color based on silo type
    color_class = silo_color_class(silo.type)

    assigns = assigns
              |> assign(:tau, tau)
              |> assign(:activity, activity)
              |> assign(:color_class, color_class)
              |> assign(:silo, silo)
              |> assign(:signal_display, signal_display)

    ~H"""
    <div class={[
      "relative rounded p-1.5 border transition-all duration-200",
      if(@silo.enabled, do: @color_class.bg, else: "bg-gray-800/30 opacity-50"),
      if(@silo.enabled, do: @color_class.border, else: "border-gray-700/20")
    ]}>
      <!-- Activity pulse indicator -->
      <div class={[
        "absolute top-1 right-1 w-1.5 h-1.5 rounded-full",
        case @activity do
          :high -> "bg-cyan-400 animate-pulse"
          :medium -> "bg-yellow-400"
          :low -> "bg-emerald-500"
          :inactive -> "bg-gray-600"
        end
      ]}></div>

      <!-- Silo name -->
      <div class="flex items-baseline justify-between mb-0.5">
        <span class={[
          "text-[9px] font-medium truncate",
          if(@silo.enabled, do: @color_class.text, else: "text-gray-500")
        ]}>{silo_short_name(@silo.type)}</span>
      </div>

      <!-- Time constant with temporal indicator -->
      <div class="flex items-center gap-1">
        <span class="text-[8px] text-gray-500">τ</span>
        <div class="flex-1 h-1 bg-gray-700/50 rounded-full overflow-hidden">
          <div
            class={["h-full rounded-full", @color_class.bar]}
            style={"width: #{min(100, @tau)}%"}
          ></div>
        </div>
        <span class="text-[8px] font-mono text-gray-400">{@tau}</span>
      </div>

      <!-- Signal value if available -->
      <%= case @signal_display do %>
        <% {:mutation, val} -> %>
          <div class="mt-0.5 text-[8px] font-mono text-cyan-400">μ={val}%</div>
        <% {:stagnation, val} -> %>
          <div class="mt-0.5 text-[8px] font-mono text-yellow-400">stag={val}%</div>
        <% {:memory, val} -> %>
          <div class="mt-0.5 text-[8px] font-mono text-emerald-400">mem={val}%</div>
        <% {:cpu, val} -> %>
          <div class="mt-0.5 text-[8px] font-mono text-blue-400">cpu={val}%</div>
        <% nil -> %>
          <div class="mt-0.5 h-3"></div>
      <% end %>
    </div>
    """
  end

  defp silo_short_name(:task), do: "Task"
  defp silo_short_name(:resource), do: "Resource"
  defp silo_short_name(:temporal), do: "Temporal"
  defp silo_short_name(:competitive), do: "Compete"
  defp silo_short_name(:social), do: "Social"
  defp silo_short_name(:cultural), do: "Culture"
  defp silo_short_name(:ecological), do: "Ecology"
  defp silo_short_name(:morphological), do: "Morph"
  defp silo_short_name(:developmental), do: "Develop"
  defp silo_short_name(:regulatory), do: "Regulate"
  defp silo_short_name(:economic), do: "Economic"
  defp silo_short_name(:communication), do: "Comms"
  defp silo_short_name(:distribution), do: "Distrib"
  defp silo_short_name(type), do: type |> Atom.to_string() |> String.slice(0..5)

  defp silo_color_class(:task), do: %{
    bg: "bg-purple-900/30",
    border: "border-purple-500/30",
    text: "text-purple-400",
    bar: "bg-purple-500"
  }
  defp silo_color_class(:resource), do: %{
    bg: "bg-emerald-900/30",
    border: "border-emerald-500/30",
    text: "text-emerald-400",
    bar: "bg-emerald-500"
  }
  defp silo_color_class(:temporal), do: %{
    bg: "bg-blue-900/30",
    border: "border-blue-500/30",
    text: "text-blue-400",
    bar: "bg-blue-500"
  }
  defp silo_color_class(:competitive), do: %{
    bg: "bg-red-900/30",
    border: "border-red-500/30",
    text: "text-red-400",
    bar: "bg-red-500"
  }
  defp silo_color_class(:social), do: %{
    bg: "bg-pink-900/30",
    border: "border-pink-500/30",
    text: "text-pink-400",
    bar: "bg-pink-500"
  }
  defp silo_color_class(:cultural), do: %{
    bg: "bg-amber-900/30",
    border: "border-amber-500/30",
    text: "text-amber-400",
    bar: "bg-amber-500"
  }
  defp silo_color_class(:ecological), do: %{
    bg: "bg-lime-900/30",
    border: "border-lime-500/30",
    text: "text-lime-400",
    bar: "bg-lime-500"
  }
  defp silo_color_class(:morphological), do: %{
    bg: "bg-cyan-900/30",
    border: "border-cyan-500/30",
    text: "text-cyan-400",
    bar: "bg-cyan-500"
  }
  defp silo_color_class(:developmental), do: %{
    bg: "bg-indigo-900/30",
    border: "border-indigo-500/30",
    text: "text-indigo-400",
    bar: "bg-indigo-500"
  }
  defp silo_color_class(:regulatory), do: %{
    bg: "bg-violet-900/30",
    border: "border-violet-500/30",
    text: "text-violet-400",
    bar: "bg-violet-500"
  }
  defp silo_color_class(:economic), do: %{
    bg: "bg-yellow-900/30",
    border: "border-yellow-500/30",
    text: "text-yellow-400",
    bar: "bg-yellow-500"
  }
  defp silo_color_class(:communication), do: %{
    bg: "bg-teal-900/30",
    border: "border-teal-500/30",
    text: "text-teal-400",
    bar: "bg-teal-500"
  }
  defp silo_color_class(:distribution), do: %{
    bg: "bg-orange-900/30",
    border: "border-orange-500/30",
    text: "text-orange-400",
    bar: "bg-orange-500"
  }
  defp silo_color_class(_), do: %{
    bg: "bg-gray-900/30",
    border: "border-gray-500/30",
    text: "text-gray-400",
    bar: "bg-gray-500"
  }

  # Event Stream - Scrollable
  defp event_stream(assigns) do
    ~H"""
    <div class="bg-gray-800/50 rounded-lg border border-gray-700/30 flex-1 min-h-0 flex flex-col">
      <div class="flex items-center justify-between px-3 py-2 border-b border-gray-700/30">
        <span class="text-xs font-medium text-gray-400">Event Stream</span>
        <span class="text-[10px] text-gray-500">{length(@events)} events</span>
      </div>

      <div class="flex-1 overflow-y-auto p-2 space-y-1 max-h-32">
        <%= if @events == [] do %>
          <div class="text-center text-gray-500 text-[10px] py-4">Waiting for events...</div>
        <% else %>
          <%= for event <- Enum.take(@events, 10) do %>
            <.event_item event={event} />
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp event_item(assigns) do
    ~H"""
    <div class="flex items-center gap-2 text-[10px] bg-gray-700/30 rounded px-2 py-1">
      <span class={[
        "w-1.5 h-1.5 rounded-full flex-shrink-0",
        event_color(@event.type)
      ]}></span>
      <span class="text-gray-500 font-mono">{@event.silo}</span>
      <span class="text-gray-400 truncate flex-1">{@event.message}</span>
      <span class="text-gray-600">{format_time(@event.timestamp)}</span>
    </div>
    """
  end

  defp event_color(:signals), do: "bg-blue-400"
  defp event_color(:signal), do: "bg-cyan-400"
  defp event_color(:recommendation), do: "bg-purple-400"
  defp event_color(:lifecycle), do: "bg-yellow-400"
  defp event_color(_), do: "bg-gray-400"

  defp format_time(timestamp) when is_integer(timestamp) do
    now = System.system_time(:millisecond)
    diff = now - timestamp
    cond do
      diff < 1000 -> "now"
      diff < 60_000 -> "#{div(diff, 1000)}s"
      true -> "#{div(diff, 60_000)}m"
    end
  end
  defp format_time(_), do: "-"

  # AI Insights Panel
  defp insights_panel(assigns) do
    ~H"""
    <div class="bg-gray-800/50 rounded-lg border border-gray-700/30">
      <div class="flex items-center gap-2 px-3 py-2 border-b border-gray-700/30">
        <span class="text-xs">🤖</span>
        <span class="text-xs font-medium text-gray-400">AI Insights</span>
      </div>

      <div class="p-2 space-y-1.5">
        <%= if @insights == [] do %>
          <div class="text-center text-gray-500 text-[10px] py-2">
            <span class="text-emerald-400">✓</span> System operating normally
          </div>
        <% else %>
          <%= for insight <- @insights do %>
            <.insight_item insight={insight} />
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp insight_item(assigns) do
    ~H"""
    <div class={[
      "flex items-start gap-2 text-[10px] rounded px-2 py-1.5",
      insight_bg(@insight.type)
    ]}>
      <span class="flex-shrink-0">{@insight.icon}</span>
      <span class={insight_text(@insight.type)}>{@insight.message}</span>
    </div>
    """
  end

  defp insight_bg(:critical), do: "bg-red-900/30 border border-red-500/20"
  defp insight_bg(:warning), do: "bg-yellow-900/20 border border-yellow-500/20"
  defp insight_bg(:action), do: "bg-purple-900/20 border border-purple-500/20"
  defp insight_bg(:success), do: "bg-emerald-900/20 border border-emerald-500/20"
  defp insight_bg(:info), do: "bg-blue-900/20 border border-blue-500/20"
  defp insight_bg(_), do: "bg-gray-700/30"

  defp insight_text(:critical), do: "text-red-300"
  defp insight_text(:warning), do: "text-yellow-300"
  defp insight_text(:action), do: "text-purple-300"
  defp insight_text(:success), do: "text-emerald-300"
  defp insight_text(:info), do: "text-blue-300"
  defp insight_text(_), do: "text-gray-400"

  defp format_number(nil), do: "0"
  defp format_number(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 1)
  defp format_number(n) when is_integer(n), do: Integer.to_string(n)
  defp format_number(_), do: "0"
end
