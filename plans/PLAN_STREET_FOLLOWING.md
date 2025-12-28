# Street-Following Agents Plan

**Status:** Complete (Phases 1-3)
**Created:** 2025-12-28
**Last Updated:** 2025-12-28
**Scope:** Make agents follow real streets from OpenStreetMap

---

## Overview

Agents should spawn on and move along real streets, using OpenStreetMap road network data. This creates a more realistic simulation where agents navigate the actual urban environment.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    RoadNetwork Module                        │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              road_network.ex                         │    │
│  │  - Fetch roads from Overpass API                     │    │
│  │  - Build graph of intersections + segments           │    │
│  │  - Cache road data locally                           │    │
│  │  - Provide pathfinding (A*)                          │    │
│  └─────────────────────────────────────────────────────┘    │
│                          │                                   │
│              get_roads_near(lat, lon, radius_m)              │
│              find_path(from_node, to_node)                   │
│              snap_to_road(lat, lon)                          │
│              get_random_road_point()                         │
│                          ▼                                   │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                    WorldServer (modified)                    │
│  - Spawn agents on road nodes                               │
│  - Agent movement follows road segments                     │
│  - Direction determined by road path                        │
│  - At intersections: choose next road segment               │
└─────────────────────────────────────────────────────────────┘
```

---

## Implementation Phases

### Phase 1: Road Network Data ✅ COMPLETE

**Goal:** Fetch and cache road network from OpenStreetMap

**Files:**
- `lib/swai_node/geo/road_network.ex` - Main module
- `lib/swai_node/geo/overpass_client.ex` - Overpass API client
- `lib/swai_node/geo/road_graph.ex` - Graph data structure

**Overpass Query:**
```
[out:json][timeout:30];
(
  way["highway"~"primary|secondary|tertiary|residential|unclassified|footway|path"]
    ({{bbox}});
);
out body;
>;
out skel qt;
```

**Data Structure:**
```elixir
%RoadNetwork{
  nodes: %{node_id => {lat, lon}},
  edges: %{node_id => [{neighbor_id, distance_m, road_type}]},
  segments: %{segment_id => [node_id, ...]},  # Ordered points
  bbox: {min_lat, min_lon, max_lat, max_lon}
}
```

**API:**
```elixir
RoadNetwork.load(lat, lon, radius_m)  # Fetch and cache
RoadNetwork.snap_to_road(lat, lon)    # Find nearest road point
RoadNetwork.random_point()            # Random point on a road
RoadNetwork.find_path(from, to)       # A* pathfinding
RoadNetwork.get_segment_points(id)    # Get road polyline
```

---

### Phase 2: Agent Spawning on Roads ✅ COMPLETE

**Status:** IMPLEMENTED

**Decision:** Option B (clustered origin) + Option D (breed near parent)

**Spawning Rules:**

1. **Initial Population:**
   - All agents spawn clustered around node origin (configured lat/lon)
   - Use roads within ~50m of origin point
   - Snap to nearest road if exact point not on road

2. **Breeding (new agents from reproduction):**
   - Child spawns on same road segment as parent
   - Small random offset along the segment (±10-20m)
   - If parent's road is crowded, try adjacent connected roads

3. **Respawn (after death, if population below minimum):**
   - Spawn at origin cluster (like initial spawn)
   - Maintains the "home base" concept

**Result:** Population starts at home, expands organically along roads as successful lineages breed outward. Creates natural territorial expansion.

**Changes to WorldServer:**
```elixir
defp spawn_initial_agent(state) do
  # Get roads near origin
  {lat, lon, node_id} = RoadNetwork.random_road_point_near(
    state.config.origin_lat,
    state.config.origin_lon,
    50  # meters radius
  )

  # Convert to world coordinates
  {x, y} = lat_lon_to_world(lat, lon, state.config)

  create_agent(x, y, node_id, state)
end

defp spawn_child(parent, state) do
  # Spawn near parent's location
  parent_node = parent.road_node

  # Get a nearby point on connected roads
  {lat, lon, node_id} = RoadNetwork.random_road_point_near_node(
    parent_node,
    20  # meters offset
  )

  {x, y} = lat_lon_to_world(lat, lon, state.config)

  create_agent_from_parent(x, y, node_id, parent, state)
end
```

**New RoadNetwork API needed:**
```elixir
RoadNetwork.random_road_point_near(lat, lon, radius_m)
RoadNetwork.random_road_point_near_node(node_id, radius_m)
```

---

### Phase 3: Road-Constrained Movement ✅ COMPLETE

**Goal:** Agents move along roads, not through buildings

**Movement Logic:**
```elixir
defp update_agent_position(agent, road_network) do
  cond do
    # No target - pick random destination
    is_nil(agent.target_node) ->
      target = RoadNetwork.random_intersection()
      path = RoadNetwork.find_path(agent.road_node, target)
      %{agent | target_node: target, path: path}

    # Has path - move along it
    agent.path != [] ->
      [next_point | rest] = agent.path
      {nx, ny} = next_point

      # Move toward next point
      dx = nx - agent.x
      dy = ny - agent.y
      dist = :math.sqrt(dx*dx + dy*dy)

      if dist < agent.speed do
        # Reached point, advance path
        %{agent | x: nx, y: ny, path: rest}
      else
        # Move toward point
        ratio = agent.speed / dist
        %{agent |
          x: agent.x + dx * ratio,
          y: agent.y + dy * ratio,
          direction: :math.atan2(dy, dx)
        }
      end

    # Reached destination - pick new one
    true ->
      %{agent | target_node: nil}
  end
end
```

---

### Phase 4: Visual Road Overlay (Optional)

**Goal:** Show roads on the map canvas for debugging

**Changes to world_map.js:**
```javascript
// Draw road network as lines
drawRoads(ctx, roadSegments, pixelsPerMeter) {
  ctx.strokeStyle = 'rgba(100, 100, 100, 0.3)';
  ctx.lineWidth = 2;

  roadSegments.forEach(segment => {
    ctx.beginPath();
    segment.points.forEach((point, i) => {
      const pixel = this.latLonToPixel(point.lat, point.lon);
      if (i === 0) ctx.moveTo(pixel.x, pixel.y);
      else ctx.lineTo(pixel.x, pixel.y);
    });
    ctx.stroke();
  });
}
```

---

## Data Flow

```
1. On startup:
   - RoadNetwork.load(config.latitude, config.longitude, 500)
   - Fetches ~500m radius of roads from Overpass API
   - Builds graph, caches in ETS

2. On agent spawn:
   - RoadNetwork.random_point() -> {x, y, node_id}
   - Agent created at road position

3. On tick:
   - Each agent follows its path along roads
   - At intersections, picks new random destination
   - Pathfinding via A* on road graph

4. On render:
   - Agent positions are already on roads
   - Optional: draw road overlay
```

---

## Considerations

### Caching
- Cache road data in ETS for fast access
- Re-fetch if node location changes significantly
- Consider pre-downloading for offline use

### Performance
- A* pathfinding can be expensive with many agents
- Consider caching common paths
- Limit path recalculation frequency

### Edge Cases
- Agent dies on road - no special handling needed
- New agent spawns - always on road
- Combat - happens at road positions

### Scale
- 500m radius is ~100-500 road segments
- Graph with ~50-200 intersections
- A* on small graph is fast (<1ms)

---

## Files to Create/Modify

| File | Action | Purpose |
|------|--------|---------|
| `lib/swai_node/geo/road_network.ex` | Create | Main road network module |
| `lib/swai_node/geo/overpass_client.ex` | Create | Overpass API client |
| `lib/swai_node/geo/road_graph.ex` | Create | Graph + A* pathfinding |
| `lib/swai_node/simulation/world_server.ex` | Modify | Use road network for spawning/movement |
| `config/config.exs` | Modify | Add road network config |
| `assets/js/hooks/world_map.js` | Modify | Optional road overlay |

---

## Success Criteria

- [x] Road data fetched from OpenStreetMap on startup
- [x] Agents spawn only on road positions
- [x] Agents move along roads (not through buildings)
- [x] Agents navigate intersections correctly (A* pathfinding)
- [x] Performance remains smooth with 50+ agents (80 agents running)
- [x] Food spawns only on streets (not in buildings/open areas)
- [x] No arena boundaries - agents can travel entire road network

---

## Dependencies

- HTTP client (already have: Req or HTTPoison)
- JSON parsing (already have: Jason)
- No new dependencies required

---

## Estimated Complexity

- **Phase 1 (Road Data):** Medium - API integration + data structures
- **Phase 2 (Spawning):** Easy - Simple integration
- **Phase 3 (Movement):** Medium - Pathfinding + state management
- **Phase 4 (Visual):** Easy - Optional overlay

Total: ~4-6 hours of implementation
