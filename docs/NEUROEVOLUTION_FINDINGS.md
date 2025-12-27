# Neuroevolution Findings from SwaiNode Testbed

**Date:** 2025-12-27
**Status:** Active development

This document captures lessons learned from using swai-node as a testbed for macula-neuroevolution and macula-tweann. These findings should inform improvements to the core libraries.

---

## Issue 1: Vision System Cannot Distinguish Object Types

### Problem

The original vision system returned a single distance value per ray, representing the distance to the **nearest object** (food, agent, or wall). This made it impossible for agents to evolve food-seeking behavior because they couldn't distinguish between edible food and other obstacles.

```elixir
# OLD: Returns 8 floats - distance to nearest object
vision = [0.3, 0.8, 1.0, 0.5, 0.2, 1.0, 0.7, 0.4]
# Agent sees "something at 0.3" but doesn't know if it's food or enemy
```

### Solution

Split vision into **3 separate channels** per ray:
- Food distance (green channel)
- Agent distance (red channel)
- Wall distance (blue channel)

```elixir
# NEW: Returns 24 floats - 8 rays × 3 channels
# [food_0..food_7, agent_0..agent_7, wall_0..wall_7]
vision = [
  0.3, 1.0, 1.0, 0.5, 1.0, 1.0, 1.0, 1.0,  # Food distances
  1.0, 0.8, 1.0, 1.0, 0.2, 1.0, 0.7, 1.0,  # Agent distances
  1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.4   # Wall distances
]
# Agent can now see "food at 0.3 ahead, enemy at 0.2 behind-left"
```

### Recommendation for macula-neuroevolution

Add a **vision system abstraction** to the library that supports:
1. Configurable number of rays
2. Configurable object type channels
3. Optional combined "nearest object" mode for backwards compatibility

```erlang
%% Proposed API
-spec create_vision_system(Config) -> VisionSystem when
    Config :: #{
        ray_count => pos_integer(),        % Default: 8
        channels => [atom()],              % e.g., [food, agent, wall, hazard]
        max_range => float(),              % Default: 100.0
        combined_mode => boolean()         % Return single value vs per-channel
    }.
```

---

## Issue 2: Energy Parameters Not Dynamically Tunable

### Problem

Simulation parameters like `move_cost`, `eat_gain`, and `food_spawn_rate` are hardcoded as module attributes. This prevents:
1. Dynamic tuning based on population performance
2. The ecological_silo from controlling resource pressure
3. Curriculum learning (start easy, increase difficulty)

### Current State

```elixir
# world_server.ex - hardcoded constants
@move_cost 0.05
@eat_gain 40.0
@eat_range 18.0
```

### Solution (TODO)

Wire these to the ecological_silo:

```elixir
# Proposed: Read from ecological_silo state
defp get_move_cost(state) do
  case :ecological_silo.get_params(:ecological_silo) do
    %{move_cost: cost} -> cost
    _ -> @default_move_cost
  end
end
```

### Recommendation for macula-neuroevolution

1. Add **resource parameters** to ecological_silo's actuators:
   ```erlang
   -define(DEFAULT_PARAMS, #{
       %% Existing
       carrying_capacity => 100,
       resource_regeneration_rate => 0.05,
       %% New: Evaluator-specific parameters
       move_cost => 0.1,
       eat_gain => 40.0,
       food_spawn_rate => 0.8
   }).
   ```

2. Define a **parameter provider** behaviour that evaluators can implement:
   ```erlang
   -callback get_simulation_params(SiloState) -> SimParams.
   ```

---

## Issue 3: Network Topology Coupling

### Problem

When the input size changes (e.g., from 21 to 37 for new vision), multiple files need updating:
- AgentBrain module
- TrainingServer config
- WorldEvaluator docs
- Any serialization/deserialization code

### Recommendation for macula-neuroevolution

Add a **topology registry** that evaluators register with:

```erlang
%% Evaluator declares its topology requirements
-callback network_topology() ->
    {InputSize :: pos_integer(),
     HiddenLayers :: [pos_integer()],
     OutputSize :: pos_integer()}.

%% neuroevolution_server reads from evaluator
init(Config) ->
    Evaluator = maps:get(evaluator_module, Config),
    Topology = Evaluator:network_topology(),
    ...
```

This ensures topology is defined in one place (the evaluator).

---

## Issue 4: Missing Domain-Specific Fitness Components

### Current Approach

Fitness is calculated as:
```elixir
fitness = ticks_survived * 1.0 + food_eaten * 50.0 + kills * 100.0
```

### Observation

This simple linear combination works but doesn't capture nuance:
- No reward for energy efficiency
- No reward for exploration vs exploitation balance
- No multi-objective optimization

### Recommendation for macula-neuroevolution

Consider adding a **fitness composition** system:

```erlang
%% Evaluator returns structured metrics
-callback evaluate(Individual, Options) ->
    {ok, #{
        primary_fitness := float(),
        metrics := #{atom() => float()}  % For analysis
    }}.

%% Optional: Multi-objective support
-type fitness_objective() :: {Name :: atom(), Weight :: float()}.
```

---

## Issue 5: Silo Integration Gap

### Problem

The silos (ecological, morphological, etc.) are running but not integrated with the domain simulation. They collect internal metrics but don't influence the world parameters.

### Current State

```
silos are running → collecting internal stats → not affecting world_server
```

### Desired State

```
silos observe → compute optimal parameters → apply to world_server → silos observe results
```

### Recommendation

Create a **silo-evaluator bridge** pattern:

1. Evaluator publishes domain events to silo topics
2. Silos compute optimal parameters
3. Evaluator polls/subscribes to parameter updates
4. Parameters affect next evaluation batch

---

## Architecture Insights

### What Works Well

1. **Separation of concerns**: WorldSimulator (pure) vs WorldServer (GenServer) is clean
2. **Event-driven updates**: PubSub for dashboard works great
3. **Evaluator behaviour**: Clean interface between training and simulation

### What Could Be Improved

1. **Vision abstraction**: Should be a reusable library pattern
2. **Parameter wiring**: Silos should control simulation parameters
3. **Topology management**: Should be derived from evaluator, not duplicated
4. **Fitness composition**: Should support multi-objective goals

---

## Next Steps

1. [ ] Wire ecological_silo to control move_cost, eat_gain, food_spawn_rate
2. [ ] Create vision system abstraction in macula-tweann
3. [ ] Add parameter provider behaviour to neuroevolution
4. [ ] Test with ecological_silo dynamically adjusting difficulty

---

## Files Modified

| File | Change |
|------|--------|
| `vision.ex` | Multi-channel vision (24 outputs vs 8) |
| `agent_brain.ex` | Updated for 37 inputs, [48, 24] hidden |
| `world_server.ex` | Reduced move_cost to 0.05 |
| `world_simulator.ex` | Reduced move_cost to 0.05 |
| `training_server.ex` | Updated topology to {37, [48, 24], 6} |
| `world_evaluator.ex` | Updated docs |
