# Screaming Architecture Refactoring for macula-neuroevolution

**Date:** 2025-12-27
**Status:** Proposal
**Context:** Applying vertical slicing and screaming architecture principles

---

## Current Structure Analysis

### What's Good (Already Vertical)

The `liquid_conglomerate/` silos are **already well-organized**:

```
liquid_conglomerate/
├── ecological_silo/           ✓ Vertical: silo + events
├── competitive_silo/          ✓ Vertical: silo + events
├── task_silo/                 ✓ Vertical: silo + sensors + actuators + morphology
├── resource_silo/             ✓ Vertical: silo + sensors + actuators + morphology
├── distribution_silo/         ✓ Vertical: silo + sensors + actuators + morphology
└── ... (13 silos total)
```

### What's Bad (Horizontal/Chaotic)

**Root level chaos** - ~20 files with mixed concerns:

```
src/
├── neuroevolution_server.erl      # Core loop
├── neuroevolution_evaluator.erl   # Evaluation behaviour
├── neuroevolution_genetic.erl     # Genetic operators
├── neuroevolution_selection.erl   # Selection
├── neuroevolution_speciation.erl  # Species
├── neuroevolution_stats.erl       # Statistics
├── neuroevolution_events.erl      # Events
├── neuroevolution_events_local.erl
├── neuroevolution_behavioral_events.erl
├── neuroevolution_lineage_events.erl
├── neuroevolution_evaluator_worker.erl
├── meta_config.erl                # Meta-learning config
├── meta_controller.erl            # Meta-learning controller
├── meta_reward.erl                # Meta-learning rewards
├── meta_trainer.erl               # Meta-learning trainer
├── network_factory.erl            # Factory
├── genome_factory.erl             # Factory
├── checkpoint_manager.erl         # Persistence
├── resource_monitor.erl           # Monitoring
├── nif_network.erl                # NIF integration
├── elixir_evaluator_bridge.erl    # Bridge
└── neuro_config.erl               # Config
```

**Horizontal groupings:**

```
strategies/           # "Things that are strategies"
lc_morphologies/      # "Things that are morphologies"
mesh/                 # "Things that are mesh-related"
```

**Buried shared utilities:**

```
liquid_conglomerate/
├── lc_controller.erl       # Shared controller
├── lc_supervisor.erl       # Shared supervisor
├── lc_silo_behavior.erl    # Shared behaviour
├── lc_cross_silo.erl       # Shared communication
├── lc_chain.erl            # Shared chain
├── lc_population.erl       # Population tracking
├── lc_reward.erl           # Reward computation
├── lc_event_emitter.erl    # Event emission
├── lc_ets_utils.erl        # ETS helpers
├── lc_sensor_publisher.erl # Sensor publishing
└── ... (12 shared files)
```

---

## Proposed Screaming Architecture

### Design Principle

**Folder names should answer: "What does this DO?"**

Not: "What type of thing IS this?"

### New Structure

```
macula-neuroevolution/src/
│
├── evolve/                           %% WHAT: Run neuroevolution
│   ├── neuroevolution_server.erl     %%   The main evolution loop
│   ├── population.erl                %%   Population management
│   ├── individual.erl                %%   Individual lifecycle (was genome_factory + network_factory)
│   ├── species.erl                   %%   Species management (was neuroevolution_speciation)
│   ├── selection.erl                 %%   Selection operators
│   ├── genetic.erl                   %%   Genetic operators (mutation, crossover)
│   └── events.erl                    %%   Evolution events
│
├── strategies/                       %% WHAT: Different evolution paradigms (top-level)
│   ├── strategy.erl                  %%   Behaviour definition
│   ├── generational.erl              %%   Traditional (μ,λ) evolution
│   ├── steady_state.erl              %%   Continuous replacement
│   ├── island.erl                    %%   Parallel populations
│   ├── novelty.erl                   %%   Behavioral novelty search
│   ├── map_elites.erl                %%   Quality-diversity
│   └── coevolution/                  %%   Competitive coevolution
│       ├── manager.erl
│       ├── archive_crdt.erl
│       └── red_team.erl
│
├── evaluate/                         %% WHAT: Compute fitness
│   ├── evaluator.erl                 %%   Behaviour (domains implement this)
│   ├── evaluator_worker.erl          %%   Worker process
│   ├── elixir_bridge.erl             %%   Elixir evaluator support
│   └── nif_network.erl               %%   NIF-based network execution
│
├── silos/                            %% WHAT: Self-tuning subsystems (Liquid Conglomerate)
│   │
│   ├── silo.erl                      %%   Silo behaviour (was lc_silo_behavior)
│   ├── supervisor.erl                %%   Silo supervision (was lc_supervisor)
│   ├── coordinator.erl               %%   Cross-silo coordination (was lc_cross_silo)
│   ├── signal_router.erl             %%   Routes domain signals to silos (NEW)
│   │
│   ├── ecological/                   %%   WHAT: Resource pressure & carrying capacity
│   │   ├── ecological_silo.erl
│   │   ├── sensors.erl               %%   (if needed)
│   │   ├── actuators.erl             %%   (if needed)
│   │   └── events.erl
│   │
│   ├── competitive/                  %%   WHAT: Inter-agent competition
│   │   ├── competitive_silo.erl
│   │   └── events.erl
│   │
│   ├── morphological/                %%   WHAT: Network topology evolution
│   │   ├── morphological_silo.erl
│   │   └── events.erl
│   │
│   ├── regulatory/                   %%   WHAT: Homeostasis & thresholds
│   │   ├── regulatory_silo.erl
│   │   └── events.erl
│   │
│   ├── task/                         %%   WHAT: Hyperparameter tuning
│   │   ├── task_silo.erl
│   │   ├── sensors.erl
│   │   ├── actuators.erl
│   │   ├── morphology.erl
│   │   ├── defaults.erl
│   │   └── events.erl
│   │
│   ├── resource/                     %%   WHAT: Resource allocation
│   │   ├── resource_silo.erl
│   │   ├── sensors.erl
│   │   ├── actuators.erl
│   │   ├── morphology.erl
│   │   └── events.erl
│   │
│   ├── distribution/                 %%   WHAT: Distributed evaluation control
│   │   ├── distribution_silo.erl
│   │   ├── sensors.erl
│   │   ├── actuators.erl
│   │   ├── morphology.erl
│   │   └── events.erl
│   │
│   ├── temporal/                     %%   WHAT: Time-based dynamics
│   │   ├── temporal_silo.erl
│   │   └── events.erl
│   │
│   ├── developmental/                %%   WHAT: Growth stages & maturation
│   │   ├── developmental_silo.erl
│   │   └── events.erl
│   │
│   ├── cultural/                     %%   WHAT: Memetic evolution
│   │   ├── cultural_silo.erl
│   │   └── events.erl
│   │
│   ├── social/                       %%   WHAT: Social structures
│   │   ├── social_silo.erl
│   │   └── events.erl
│   │
│   ├── communication/                %%   WHAT: Signal exchange
│   │   ├── communication_silo.erl
│   │   └── events.erl
│   │
│   └── economic/                     %%   WHAT: Resource trading
│       ├── economic_silo.erl
│       └── events.erl
│
├── domain/                           %% WHAT: Connect to external domains
│   ├── domain_sensors.erl            %%   Behaviour: what sensors does domain provide?
│   ├── domain_actuators.erl          %%   Behaviour: what actuators does domain accept?
│   └── domain_rewards.erl            %%   Behaviour: what rewards does domain emit?
│
├── meta/                             %% WHAT: L1/L2 level adaptation
│   ├── l0_morphology.erl             %%   L0 network structure
│   ├── l1_controller.erl             %%   L1 hyperparameter control
│   ├── l1_morphology.erl             %%   L1 network structure
│   ├── l2_controller.erl             %%   L2 architecture control
│   ├── l2_morphology.erl             %%   L2 network structure
│   ├── meta_trainer.erl              %%   Meta-learning trainer
│   └── meta_reward.erl               %%   Meta-learning rewards
│
├── distribute/                       %% WHAT: Spread evaluation across nodes
│   ├── mesh.erl                      %%   Mesh network integration
│   ├── mesh_supervisor.erl           %%   Supervision
│   ├── distributed_evaluator.erl     %%   Remote evaluation
│   └── pool_registry.erl             %%   Worker pool management
│
├── persist/                          %% WHAT: Save/load state
│   └── checkpoint_manager.erl        %%   Checkpoint management
│
├── stats/                            %% WHAT: Monitor & report
│   ├── stats.erl                     %%   Statistics collection
│   └── resource_monitor.erl          %%   Resource monitoring
│
├── config/                           %% WHAT: Configuration
│   ├── neuro_config.erl              %%   Main config
│   └── meta_config.erl               %%   Meta-learning config
│
├── macula_neuroevolution_app.erl
└── macula_neuroevolution_sup.erl
```

---

## Key Changes Summary

### 1. Root Level → Organized Folders

| Old Location | New Location | Rationale |
|--------------|--------------|-----------|
| `neuroevolution_server.erl` | `evolve/neuroevolution_server.erl` | Core evolution belongs in `evolve/` |
| `neuroevolution_speciation.erl` | `evolve/species.erl` | Shorter, clearer name |
| `neuroevolution_selection.erl` | `evolve/selection.erl` | Drop redundant prefix |
| `neuroevolution_genetic.erl` | `evolve/genetic.erl` | Drop redundant prefix |
| `genome_factory.erl` + `network_factory.erl` | `evolve/individual.erl` | Merge related factories |
| `meta_*.erl` | `meta/` folder | Group meta-learning |
| `checkpoint_manager.erl` | `persist/checkpoint_manager.erl` | Clear purpose |

### 2. strategies/ stays top-level

Strategies remain as a top-level folder. Move `coevolution/` under it.

### 3. liquid_conglomerate/ → silos/

- Shorter, more descriptive name
- Keep the already-good vertical structure of each silo
- Move shared utilities to `silos/` root
- Rename `lc_*` prefixes → clearer names

### 4. mesh/ → distribute/

"Mesh" is an implementation detail. "Distribute" screams intent.

### 5. lc_morphologies/ → meta/

These are meta-learning concerns (L0/L1/L2 adaptation).

### 6. NEW: domain/

Add the domain bridge behaviours we designed.

---

## Module Renaming Summary

| Old Name | New Name | Reason |
|----------|----------|--------|
| `lc_silo_behavior` | `silo` | Clearer, shorter |
| `lc_supervisor` | `silos/supervisor` | Context from folder |
| `lc_cross_silo` | `silos/coordinator` | Intent-focused |
| `lc_controller` | `silos/controller` | Context from folder |
| `lc_chain` | `silos/chain` | Context from folder |
| `lc_population` | `evolve/population` | Belongs with evolution |
| `lc_reward` | `silos/reward` | Silo-specific |
| `neuroevolution_speciation` | `evolve/species` | Shorter |
| `neuroevolution_selection` | `evolve/selection` | Drop prefix |
| `neuroevolution_genetic` | `evolve/genetic` | Drop prefix |
| `neuroevolution_evaluator` | `evaluate/evaluator` | Context from folder |

---

## Benefits

1. **Screaming Architecture**: Looking at `src/` immediately shows:
   - `evolve/` - This library evolves things
   - `silos/` - It has self-tuning subsystems
   - `evaluate/` - It evaluates fitness
   - `domain/` - It connects to domains
   - `distribute/` - It can distribute work

2. **Vertical Slicing**: Each folder is self-contained:
   - `silos/ecological/` has everything about ecological pressure
   - `evolve/strategies/coevolution/` has everything about coevolution

3. **Discoverability**: A new developer can navigate by intent:
   - "How do I run evolution?" → `evolve/`
   - "How do I add a new silo?" → `silos/` + look at any existing silo

4. **Reduced Cognitive Load**: No more `lc_` prefixes everywhere - the folder provides context.

---

## Migration Strategy

1. **Phase 1**: Create new folder structure (empty)
2. **Phase 2**: Move files with `git mv` (preserves history)
3. **Phase 3**: Update module names in code
4. **Phase 4**: Update include paths
5. **Phase 5**: Update exports in `.app.src`
6. **Phase 6**: Run tests, fix any issues

---

## Decisions

1. **`evolve/` naming**: Keep as `evolve/` - clear and concise
2. **strategies/ location**: Keep top-level, not nested under `evolve/`
3. **`_silo` suffix**: Keep the suffix on silo modules for clarity
4. **Backwards compatibility**: Not a concern - still in development, no guarantees

---

## Next Steps

1. [ ] Review and approve this proposal
2. [ ] Create migration script
3. [ ] Execute migration in macula-neuroevolution
4. [ ] Update documentation
5. [ ] Release new version with deprecation warnings for old paths
