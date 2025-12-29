# Macula Neuroevolution Application Architecture

This document describes the standard architecture pattern for applications built on `macula-neuroevolution`.

## Core Principle

**The application defines the domain. The library provides evolution.**

Applications should NOT implement evolution algorithms. They should:
1. Define their domain (agents, environment, rewards)
2. Implement evaluator behaviour
3. Subscribe to evolution events
4. Build projections from events
5. Visualize results

## Architecture Layers

```
┌─────────────────────────────────────────────────────────────────┐
│                        APPLICATION                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────────┐  ┌──────────────────┐  ┌───────────────┐ │
│  │  Domain          │  │  Evaluator       │  │  Coordinator  │ │
│  │  Definition      │  │  (Behaviour)     │  │  (GenServer)  │ │
│  │                  │  │                  │  │               │ │
│  │  - Sensors       │  │  - evaluate/2    │  │  - start/stop │ │
│  │  - Actuators     │  │  - calc_fitness  │  │  - config     │ │
│  │  - Rewards       │  │                  │  │  - events     │ │
│  │  - Environment   │  │                  │  │               │ │
│  └──────────────────┘  └──────────────────┘  └───────────────┘ │
│           │                     │                    │          │
│           └─────────────────────┼────────────────────┘          │
│                                 │                               │
│                          PubSub Events                          │
│                                 │                               │
│           ┌─────────────────────┼────────────────────┐          │
│           ▼                     ▼                    ▼          │
│  ┌──────────────────┐  ┌──────────────────┐  ┌───────────────┐ │
│  │  Projections     │  │  Visualization   │  │  LC Silos     │ │
│  │                  │  │                  │  │  Wiring       │ │
│  │  - FitnessHist   │  │  - Dashboard     │  │               │ │
│  │  - ChampionArch  │  │  - Charts        │  │  - task_silo  │ │
│  │  - SpeciesDiv    │  │  - Arena         │  │  - resource   │ │
│  └──────────────────┘  └──────────────────┘  └───────────────┘ │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
                                 │
                                 │ implements behaviours
                                 │ receives events
                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│                   MACULA-NEUROEVOLUTION LIBRARY                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  - Evolution algorithms (selection, mutation, crossover)         │
│  - Population management                                         │
│  - TWEANN topology evolution                                     │
│  - LC silo infrastructure                                        │
│  - Event publishing                                              │
│  - Behaviour definitions                                         │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Application Components

### 1. Domain Definition (`domain/*.ex`)

Defines the problem space:

```elixir
defmodule MyApp.Domain.MyArena do
  # Network topology
  def input_count, do: 29
  def hidden_layers, do: [32, 16]
  def output_count, do: 9
  def network_topology, do: {input_count(), hidden_layers(), output_count()}

  # Environment parameters
  def arena_radius, do: 40
  def max_food, do: 80

  # Agent parameters
  def starting_energy, do: 150.0
  def move_cost, do: 0.3

  # Reward function
  def calculate_fitness(metrics) do
    ticks = Map.get(metrics, :ticks_survived, 0)
    food = Map.get(metrics, :food_eaten, 0)
    ticks * 0.5 + food * 50.0
  end

  # Sensor/actuator specs for documentation
  def sensor_spec, do: [...]
  def actuator_spec, do: [...]
end
```

### 2. Evaluator (`training/my_evaluator.ex`)

Implements the neuroevolution_evaluator behaviour:

```elixir
defmodule MyApp.Training.MyEvaluator do
  @behaviour :neuroevolution_evaluator
  alias MyApp.Domain.MyArena

  @impl true
  def evaluate(individual, options) do
    network = elem(individual, 2)
    result = run_simulation(network, options)
    fitness = MyArena.calculate_fitness(result)
    metrics = build_metrics(result)

    updated = individual
      |> put_elem(6, fitness)
      |> put_elem(7, metrics)

    {:ok, updated}
  end

  @impl true
  def calculate_fitness(metrics) do
    MyArena.calculate_fitness(metrics)
  end
end
```

### 3. Training Coordinator (`training/training_server.ex`)

Thin wrapper that manages lifecycle and publishes events:

```elixir
defmodule MyApp.Training.TrainingServer do
  use GenServer

  # Responsibilities:
  # - Start/stop neuroevolution_server
  # - Configure with evaluator module
  # - Receive events and broadcast to PubSub
  # - Expose neuro_pid for live queries

  # Does NOT:
  # - Track fitness history (that's a projection)
  # - Archive champions (that's a projection)
  # - Implement any evolution logic
end
```

### 4. Projections (`projections/*.ex`)

Subscribe to events, build read models:

```elixir
defmodule MyApp.Projections.FitnessHistory do
  use GenServer

  def init(_) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "training:events")
    {:ok, %{history: []}}
  end

  def handle_info({:generation_complete, stats}, state) do
    point = %{gen: stats.generation, best: stats.best_fitness}
    history = [point | state.history] |> Enum.take(500)
    {:noreply, %{state | history: history}}
  end

  # Client API for dashboard
  def get_history, do: GenServer.call(__MODULE__, :get_history)
end
```

### 5. Visualization (`live/*.ex`, `hooks/*.js`)

Consumes projections for display:

```elixir
defmodule MyAppWeb.DashboardLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "training:events")

    {:ok, assign(socket,
      history: FitnessHistory.get_history(),
      best_fitness: ChampionArchive.get_best_fitness()
    )}
  end

  def handle_info({:generation_complete, stats}, socket) do
    {:noreply, assign(socket, stats: stats)}
  end
end
```

### 6. LC Silo Wiring (`application.ex`)

Configure which silos to enable:

```elixir
def start(_type, _args) do
  # Register domain bridge for silo communication
  :signal_router.register_domain_module(MyApp.Domain.DomainBridge)

  children = [
    {Phoenix.PubSub, name: MyApp.PubSub},
    MyApp.Training.TrainingServer,
    MyApp.Projections.FitnessHistory,
    MyApp.Projections.ChampionArchive,
    MyApp.Simulation.ArenaServer
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

## Events Published

Standard events on `training:events` topic:

| Event | Payload | Description |
|-------|---------|-------------|
| `{:training_started, config}` | Training config map | Training began |
| `{:training_stopped, stats}` | Last stats | Training stopped |
| `{:training_reset, %{}}` | Empty | Reset to new population |
| `{:generation_complete, stats}` | Gen, best, avg, pop | Generation finished |
| `{:training_complete, data}` | Final data | Max generations reached |
| `{:champion_updated, individual}` | Individual tuple | New best discovered |

## File Structure

```
my_app/
├── lib/my_app/
│   ├── application.ex           # Supervision tree
│   ├── domain/
│   │   └── my_arena.ex          # Domain definition
│   ├── training/
│   │   ├── training_server.ex   # Coordinator
│   │   └── my_evaluator.ex      # Evaluator behaviour
│   ├── projections/
│   │   ├── fitness_history.ex   # Fitness projection
│   │   └── champion_archive.ex  # Champion projection
│   └── simulation/
│       └── arena_server.ex      # Visualization server
├── lib/my_app_web/
│   └── live/
│       └── dashboard_live.ex    # Dashboard
└── assets/js/hooks/
    └── arena.js                 # Canvas rendering
```

## swai-node Example

swai-node follows this architecture:

| Component | Location |
|-----------|----------|
| Domain | `domain/hex_arena.ex` |
| Evaluator | `training/hex_world_evaluator.ex` |
| Coordinator | `training/training_server.ex` |
| Projections | `projections/fitness_history.ex`, `projections/champion_archive.ex` |
| Visualization | `simulation/hex_world_server.ex`, `live/dashboard_live.ex` |
| LC Wiring | `application.ex`, `domain/domain_bridge.ex` |

## Benefits

1. **Separation of Concerns**: Evolution stays in library, domain in app
2. **Testability**: Projections can be tested independently
3. **Flexibility**: Easy to add new projections without touching core
4. **Observability**: All state changes flow through events
5. **Replay**: Events can be replayed to rebuild projections
