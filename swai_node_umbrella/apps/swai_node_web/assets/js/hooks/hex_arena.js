/**
 * Hex Arena Canvas Renderer
 *
 * Renders a hexagonal grid arena with:
 * - Procedurally generated maze walls
 * - Agents with various visual decorators
 * - Food items
 * - Small hexagons (~12px) for fine-grained movement
 */

const HexArena = {
  // Configuration
  config: {
    hexSize: 12,      // Hex radius in pixels
    arenaRadius: 25,  // Arena radius in hex units
    colors: {
      background: '#1a1a2e',
      grid: '#2d2d44',
      wall: '#4a4a5e',
      food: '#22c55e',
      agentDefault: '#3b82f6',
      agentAggressive: '#ef4444',
      agentDiplomatic: '#8b5cf6',
      energyLow: '#fbbf24',
      energyHigh: '#22c55e',
      champion: '#fbbf24',
      attackGlow: '#ef4444'
    }
  },

  mounted() {
    this.canvas = this.el.querySelector('canvas') || this.createCanvas();
    this.ctx = this.canvas.getContext('2d');

    // State
    this.walls = new Set();
    this.agents = [];
    this.food = [];

    // Interpolation state - maps agent ID to {currentX, currentY, targetX, targetY}
    this.agentPositions = new Map();
    this.lastUpdateTime = performance.now();
    this.interpolationDuration = 50; // ms - matches tick interval

    // Zoom and pan state
    this.scale = 1.0;
    this.panX = 0;
    this.panY = 0;
    this.isPanning = false;
    this.lastMouseX = 0;
    this.lastMouseY = 0;

    // Rendering
    this.setupCanvas();
    this.startRenderLoop();
    this.setupZoomAndPan();

    // Event handlers
    this.handleEvent("arena_init", (data) => this.handleArenaInit(data));
    this.handleEvent("world_update", (data) => this.handleWorldUpdate(data));
    this.handleEvent("agent_moved", (data) => this.handleAgentMoved(data));

    // Resize handler
    this.resizeObserver = new ResizeObserver(() => this.setupCanvas());
    this.resizeObserver.observe(this.el);
  },

  setupZoomAndPan() {
    // Mouse wheel zoom
    this.canvas.addEventListener('wheel', (e) => {
      e.preventDefault();
      const rect = this.canvas.getBoundingClientRect();
      const mouseX = e.clientX - rect.left;
      const mouseY = e.clientY - rect.top;

      // Calculate zoom factor
      const zoomFactor = e.deltaY > 0 ? 0.9 : 1.1;
      const newScale = Math.max(0.2, Math.min(5, this.scale * zoomFactor));

      // Adjust pan to zoom toward mouse position
      const scaleDiff = newScale / this.scale;
      this.panX = mouseX - (mouseX - this.panX) * scaleDiff;
      this.panY = mouseY - (mouseY - this.panY) * scaleDiff;

      this.scale = newScale;
    }, { passive: false });

    // Mouse drag to pan
    this.canvas.addEventListener('mousedown', (e) => {
      if (e.button === 0) { // Left click
        this.isPanning = true;
        this.lastMouseX = e.clientX;
        this.lastMouseY = e.clientY;
        this.canvas.style.cursor = 'grabbing';
      }
    });

    this.canvas.addEventListener('mousemove', (e) => {
      if (this.isPanning) {
        const dx = e.clientX - this.lastMouseX;
        const dy = e.clientY - this.lastMouseY;
        this.panX += dx;
        this.panY += dy;
        this.lastMouseX = e.clientX;
        this.lastMouseY = e.clientY;
      }
    });

    this.canvas.addEventListener('mouseup', () => {
      this.isPanning = false;
      this.canvas.style.cursor = 'grab';
    });

    this.canvas.addEventListener('mouseleave', () => {
      this.isPanning = false;
      this.canvas.style.cursor = 'grab';
    });

    // Double-click to reset view
    this.canvas.addEventListener('dblclick', () => {
      this.scale = 1.0;
      this.panX = 0;
      this.panY = 0;
    });

    // Set initial cursor
    this.canvas.style.cursor = 'grab';
  },

  destroyed() {
    if (this.resizeObserver) {
      this.resizeObserver.disconnect();
    }
    if (this.animationFrame) {
      cancelAnimationFrame(this.animationFrame);
    }
  },

  createCanvas() {
    const canvas = document.createElement('canvas');
    canvas.style.width = '100%';
    canvas.style.height = '100%';
    this.el.appendChild(canvas);
    return canvas;
  },

  setupCanvas() {
    const rect = this.el.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;

    this.canvas.width = rect.width * dpr;
    this.canvas.height = rect.height * dpr;
    this.canvas.style.width = rect.width + 'px';
    this.canvas.style.height = rect.height + 'px';

    this.ctx.scale(dpr, dpr);

    // Calculate center offset
    this.centerX = rect.width / 2;
    this.centerY = rect.height / 2;

    // Redraw walls on resize
    this.needsWallRedraw = true;
  },

  handleArenaInit(data) {
    console.log("[HexArena] arena_init received:", data);
    if (data.config) {
      this.config.hexSize = data.config.hex_size || 12;
      this.config.arenaRadius = data.config.arena_radius || 25;
    }

    // Store walls as Set of "q,r" strings for fast lookup
    this.walls = new Set();
    if (data.walls) {
      data.walls.forEach(([q, r]) => {
        this.walls.add(`${q},${r}`);
      });
    }
    console.log("[HexArena] Loaded", this.walls.size, "walls");

    this.needsWallRedraw = true;
  },

  handleWorldUpdate(data) {
    this.agents = data.agents || [];
    this.food = data.food || [];

    // Update interpolation targets for each agent
    const now = performance.now();
    this.lastUpdateTime = now;

    this.agents.forEach(agent => {
      const id = agent.id;
      let targetX, targetY;

      if (agent.hex) {
        const [q, r] = agent.hex;
        const pos = this.hexToPixel(q, r);
        targetX = pos.x;
        targetY = pos.y;
      } else if (agent.x !== undefined) {
        targetX = this.centerX + agent.x;
        targetY = this.centerY + agent.y;
      } else {
        return;
      }

      const existing = this.agentPositions.get(id);
      if (existing) {
        // Move current position to where we interpolated to, set new target
        existing.currentX = existing.renderX || existing.currentX;
        existing.currentY = existing.renderY || existing.currentY;
        existing.targetX = targetX;
        existing.targetY = targetY;
        existing.startTime = now;
      } else {
        // New agent - start at target position (no interpolation for first frame)
        this.agentPositions.set(id, {
          currentX: targetX,
          currentY: targetY,
          targetX: targetX,
          targetY: targetY,
          renderX: targetX,
          renderY: targetY,
          startTime: now
        });
      }
    });

    // Clean up dead agents
    const aliveIds = new Set(this.agents.map(a => a.id));
    for (const id of this.agentPositions.keys()) {
      if (!aliveIds.has(id)) {
        this.agentPositions.delete(id);
      }
    }

    // If we received walls in update (fallback), use them
    if (data.walls && this.walls.size === 0) {
      data.walls.forEach(([q, r]) => {
        this.walls.add(`${q},${r}`);
      });
      this.needsWallRedraw = true;
    }
  },

  handleAgentMoved(data) {
    // Individual movement event: update just this agent's position
    const { agent_id, from_hex, to_hex, direction, tick } = data;
    const now = performance.now();

    // Calculate pixel positions
    const fromPos = this.hexToPixel(from_hex[0], from_hex[1]);
    const toPos = this.hexToPixel(to_hex[0], to_hex[1]);

    // Update or create interpolation state
    const existing = this.agentPositions.get(agent_id);
    if (existing) {
      // Start interpolating from current rendered position to new target
      existing.currentX = existing.renderX || fromPos.x;
      existing.currentY = existing.renderY || fromPos.y;
      existing.targetX = toPos.x;
      existing.targetY = toPos.y;
      existing.startTime = now;
    } else {
      // New agent - set up interpolation state
      this.agentPositions.set(agent_id, {
        currentX: fromPos.x,
        currentY: fromPos.y,
        targetX: toPos.x,
        targetY: toPos.y,
        renderX: fromPos.x,
        renderY: fromPos.y,
        startTime: now
      });
    }

    // Update the agent's hex in our local agents array
    const agent = this.agents.find(a => a.id === agent_id);
    if (agent) {
      agent.hex = to_hex;
    }

    console.log(`[agent_moved] Agent ${agent_id}: (${from_hex}) -> (${to_hex})`);
  },

  startRenderLoop() {
    const render = () => {
      this.render();
      this.animationFrame = requestAnimationFrame(render);
    };
    render();
  },

  render() {
    const ctx = this.ctx;
    const rect = this.el.getBoundingClientRect();

    // Clear canvas
    ctx.fillStyle = this.config.colors.background;
    ctx.fillRect(0, 0, rect.width, rect.height);

    // Apply zoom and pan transformations
    ctx.save();
    ctx.translate(this.panX, this.panY);
    ctx.scale(this.scale, this.scale);

    // Draw grid and walls
    this.drawGrid();

    // Draw food
    this.food.forEach(f => this.drawFood(f));

    // Draw agents
    this.agents.forEach(a => this.drawAgent(a));

    ctx.restore();

    // Draw zoom indicator in corner (not affected by transform)
    ctx.fillStyle = 'rgba(255, 255, 255, 0.5)';
    ctx.font = '10px monospace';
    ctx.fillText(`Zoom: ${Math.round(this.scale * 100)}%`, 10, rect.height - 10);
  },

  drawGrid() {
    const ctx = this.ctx;
    const hexSize = this.config.hexSize;
    const radius = this.config.arenaRadius;

    // Draw all hexes in arena
    for (let q = -radius; q <= radius; q++) {
      for (let r = -radius; r <= radius; r++) {
        // Check if in hexagonal bounds
        const s = -q - r;
        if (Math.max(Math.abs(q), Math.abs(r), Math.abs(s)) <= radius) {
          const {x, y} = this.hexToPixel(q, r);

          if (this.walls.has(`${q},${r}`)) {
            // Draw wall hex
            this.drawHex(x, y, hexSize, this.config.colors.wall, true);
          } else {
            // Draw empty hex (just outline)
            this.drawHex(x, y, hexSize, this.config.colors.grid, false);
          }
        }
      }
    }
  },

  drawHex(x, y, size, color, fill) {
    const ctx = this.ctx;
    ctx.beginPath();

    // Pointy-top hexagon
    for (let i = 0; i < 6; i++) {
      const angle = Math.PI / 180 * (60 * i - 30);
      const hx = x + size * Math.cos(angle);
      const hy = y + size * Math.sin(angle);
      if (i === 0) {
        ctx.moveTo(hx, hy);
      } else {
        ctx.lineTo(hx, hy);
      }
    }
    ctx.closePath();

    if (fill) {
      ctx.fillStyle = color;
      ctx.fill();
    } else {
      ctx.strokeStyle = color;
      ctx.lineWidth = 0.5;
      ctx.stroke();
    }
  },

  drawFood(food) {
    const hexSize = this.config.hexSize;
    let x, y;

    if (food.hex) {
      const [q, r] = food.hex;
      const pos = this.hexToPixel(q, r);
      x = pos.x;
      y = pos.y;
    } else if (food.x !== undefined) {
      x = this.centerX + food.x;
      y = this.centerY + food.y;
    } else {
      return;
    }

    // Draw food as smaller filled hex
    const ctx = this.ctx;
    ctx.beginPath();
    const foodSize = hexSize * 0.6;

    for (let i = 0; i < 6; i++) {
      const angle = Math.PI / 180 * (60 * i - 30);
      const hx = x + foodSize * Math.cos(angle);
      const hy = y + foodSize * Math.sin(angle);
      if (i === 0) {
        ctx.moveTo(hx, hy);
      } else {
        ctx.lineTo(hx, hy);
      }
    }
    ctx.closePath();

    ctx.fillStyle = this.config.colors.food;
    ctx.fill();
  },

  drawAgent(agent) {
    const ctx = this.ctx;
    const hexSize = this.config.hexSize;
    let x, y;

    // Use interpolated position for smooth movement
    const posData = this.agentPositions.get(agent.id);
    if (posData) {
      // Calculate interpolation progress
      const now = performance.now();
      const elapsed = now - posData.startTime;
      const t = Math.min(elapsed / this.interpolationDuration, 1);

      // Smooth easing
      const easeT = t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;

      // Interpolate position
      x = posData.currentX + (posData.targetX - posData.currentX) * easeT;
      y = posData.currentY + (posData.targetY - posData.currentY) * easeT;

      // Store rendered position for next frame
      posData.renderX = x;
      posData.renderY = y;
    } else if (agent.hex) {
      const [q, r] = agent.hex;
      const pos = this.hexToPixel(q, r);
      x = pos.x;
      y = pos.y;
    } else if (agent.x !== undefined) {
      x = this.centerX + agent.x;
      y = this.centerY + agent.y;
    } else {
      return;
    }

    const size = hexSize * 0.7;

    // Determine agent color based on behavior
    let color = this.config.colors.agentDefault;
    if (agent.wants_attack) {
      color = this.config.colors.agentAggressive;
    } else if (agent.signal > 0.7) {
      color = this.config.colors.agentDiplomatic;
    }

    // Draw attack glow if attacking
    if (agent.wants_attack) {
      ctx.beginPath();
      ctx.arc(x, y, size * 1.5, 0, Math.PI * 2);
      ctx.fillStyle = 'rgba(239, 68, 68, 0.3)';
      ctx.fill();
    }

    // Draw energy ring
    const energyRatio = Math.min(agent.energy / 200, 1);
    const ringColor = energyRatio > 0.5 ?
      this.config.colors.energyHigh :
      this.config.colors.energyLow;

    ctx.beginPath();
    ctx.arc(x, y, size * 1.2, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * energyRatio);
    ctx.strokeStyle = ringColor;
    ctx.lineWidth = 2;
    ctx.stroke();

    // Draw agent shape based on type
    const shape = this.getAgentShape(agent);
    this.drawShape(x, y, size, shape, color, agent.direction);

    // Draw champion aura for high fitness
    if (agent.fitness > 500) {
      ctx.beginPath();
      ctx.arc(x, y, size * 1.6, 0, Math.PI * 2);
      ctx.strokeStyle = this.config.colors.champion;
      ctx.lineWidth = 1;
      ctx.setLineDash([2, 2]);
      ctx.stroke();
      ctx.setLineDash([]);
    }
  },

  getAgentShape(agent) {
    // Shape based on behavior: herbivore=circle, carnivore=triangle, omnivore=diamond
    const kills = agent.kills || 0;
    const food = agent.food_eaten || 0;

    if (kills === 0) return 'circle';
    if (kills > food) return 'triangle';
    return 'diamond';
  },

  drawShape(x, y, size, shape, color, direction) {
    const ctx = this.ctx;
    ctx.save();
    ctx.translate(x, y);
    ctx.rotate(direction || 0);

    ctx.beginPath();

    switch (shape) {
      case 'circle':
        ctx.arc(0, 0, size, 0, Math.PI * 2);
        break;

      case 'triangle':
        ctx.moveTo(size, 0);
        ctx.lineTo(-size * 0.5, -size * 0.866);
        ctx.lineTo(-size * 0.5, size * 0.866);
        ctx.closePath();
        break;

      case 'diamond':
        ctx.moveTo(size, 0);
        ctx.lineTo(0, -size * 0.7);
        ctx.lineTo(-size, 0);
        ctx.lineTo(0, size * 0.7);
        ctx.closePath();
        break;
    }

    ctx.fillStyle = color;
    ctx.fill();
    ctx.strokeStyle = '#fff';
    ctx.lineWidth = 1;
    ctx.stroke();

    ctx.restore();
  },

  hexToPixel(q, r) {
    const size = this.config.hexSize;
    // Pointy-top hex conversion
    const x = size * (Math.sqrt(3) * q + Math.sqrt(3) / 2 * r);
    const y = size * (3 / 2 * r);
    return {
      x: this.centerX + x,
      y: this.centerY + y
    };
  },

  pixelToHex(px, py) {
    const size = this.config.hexSize;
    const x = px - this.centerX;
    const y = py - this.centerY;

    const q = (Math.sqrt(3) / 3 * x - 1 / 3 * y) / size;
    const r = (2 / 3 * y) / size;

    return this.cubeRound(q, r);
  },

  cubeRound(q, r) {
    const s = -q - r;

    let rq = Math.round(q);
    let rr = Math.round(r);
    let rs = Math.round(s);

    const qDiff = Math.abs(rq - q);
    const rDiff = Math.abs(rr - r);
    const sDiff = Math.abs(rs - s);

    if (qDiff > rDiff && qDiff > sDiff) {
      rq = -rr - rs;
    } else if (rDiff > sDiff) {
      rr = -rq - rs;
    }

    return {q: rq, r: rr};
  }
};

export default HexArena;
