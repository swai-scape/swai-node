/**
 * WorldCanvas Hook
 *
 * Renders agents and food on a canvas element with rich visual differentiation.
 * Shows generation (hue), fitness (size), and signal (glow).
 * Supports event highlighting for evolution milestones.
 */

const BASE_AGENT_RADIUS = 4;
const MAX_AGENT_RADIUS = 8;
const FOOD_RADIUS = 3;
const EVENT_DURATION_MS = 3000;  // Events fade over 3 seconds

export const WorldCanvas = {
  mounted() {
    this.canvas = this.el;
    this.ctx = this.canvas.getContext('2d');

    // Set canvas size from data attributes
    this.width = parseInt(this.el.dataset.width) || 800;
    this.height = parseInt(this.el.dataset.height) || 600;
    this.canvas.width = this.width;
    this.canvas.height = this.height;

    // Initialize empty state
    this.agents = [];
    this.food = [];
    this.events = [];  // Active visual events
    this.championId = null;  // Current champion agent ID

    // Handle world updates from server
    this.handleEvent("world_update", (payload) => {
      this.agents = payload.agents || [];
      this.food = payload.food || [];
      this.render();
    });

    // Handle evolution events for visual highlighting
    this.handleEvent("evolution_event", (payload) => {
      const now = Date.now();
      this.events.push({
        type: payload.type,
        data: payload.data || {},
        startTime: now,
        endTime: now + EVENT_DURATION_MS
      });

      // Track champion
      if (payload.type === 'champion' && payload.data?.agent_id) {
        this.championId = payload.data.agent_id;
      }

      this.render();
    });

    // Initial render
    this.render();
  },

  updated() {
    this.render();
  },

  render() {
    const ctx = this.ctx;
    const width = this.width;
    const height = this.height;
    const now = Date.now();

    // Clean up expired events
    this.events = this.events.filter(e => e.endTime > now);

    // Clear canvas with dark background
    ctx.fillStyle = '#0f0f1a';
    ctx.fillRect(0, 0, width, height);

    // Draw subtle grid
    ctx.strokeStyle = '#1a1a2e';
    ctx.lineWidth = 1;
    const gridSize = 50;
    for (let x = 0; x <= width; x += gridSize) {
      ctx.beginPath();
      ctx.moveTo(x, 0);
      ctx.lineTo(x, height);
      ctx.stroke();
    }
    for (let y = 0; y <= height; y += gridSize) {
      ctx.beginPath();
      ctx.moveTo(0, y);
      ctx.lineTo(width, y);
      ctx.stroke();
    }

    // Draw food with glow
    this.food.forEach(food => {
      const { x, y } = food;
      // Glow effect
      const gradient = ctx.createRadialGradient(x, y, 0, x, y, FOOD_RADIUS * 2);
      gradient.addColorStop(0, 'rgba(74, 222, 128, 0.8)');
      gradient.addColorStop(1, 'rgba(74, 222, 128, 0)');
      ctx.fillStyle = gradient;
      ctx.beginPath();
      ctx.arc(x, y, FOOD_RADIUS * 2, 0, Math.PI * 2);
      ctx.fill();
      // Core
      ctx.fillStyle = '#4ade80';
      ctx.beginPath();
      ctx.arc(x, y, FOOD_RADIUS, 0, Math.PI * 2);
      ctx.fill();
    });

    // Find max generation for normalization
    const maxGen = Math.max(1, ...this.agents.map(a => a.generation || 0));
    const maxFitness = Math.max(1, ...this.agents.map(a => a.fitness || 0));

    // Draw agents with rich visual differentiation
    this.agents.forEach(agent => {
      const { x, y, direction, energy, fitness, generation, signal, wants_attack, kills, id } = agent;

      // Check if this is the champion
      const isChampion = this.championId && id === this.championId;

      // Generation determines HUE (purple -> cyan -> green -> yellow -> orange)
      // This creates visual "species" based on evolutionary age
      const genRatio = (generation || 0) / maxGen;
      let hue = 270 - (genRatio * 180); // 270 (purple) -> 90 (green-yellow)

      // Hunters (agents with kills) shift toward red
      const killCount = kills || 0;
      if (killCount > 0) {
        hue = Math.max(0, hue - (killCount * 30)); // Shift toward red
      }

      // Fitness determines SIZE
      const fitnessRatio = Math.min((fitness || 0) / maxFitness, 1);
      const radius = BASE_AGENT_RADIUS + (fitnessRatio * (MAX_AGENT_RADIUS - BASE_AGENT_RADIUS));

      // Champion gets a pulsing golden aura
      if (isChampion) {
        const pulsePhase = (now % 1000) / 1000;
        const pulseSize = 1 + Math.sin(pulsePhase * Math.PI * 2) * 0.3;
        const auraRadius = radius * 3 * pulseSize;
        const gradient = ctx.createRadialGradient(x, y, radius, x, y, auraRadius);
        gradient.addColorStop(0, 'rgba(255, 215, 0, 0.6)');
        gradient.addColorStop(0.5, 'rgba(255, 180, 0, 0.3)');
        gradient.addColorStop(1, 'rgba(255, 215, 0, 0)');
        ctx.fillStyle = gradient;
        ctx.beginPath();
        ctx.arc(x, y, auraRadius, 0, Math.PI * 2);
        ctx.fill();
      }

      // Draw attack glow (red pulsing) if wanting to attack
      if (wants_attack) {
        const attackGlow = 0.7;
        const glowRadius = radius * 2.5;
        const gradient = ctx.createRadialGradient(x, y, radius, x, y, glowRadius);
        gradient.addColorStop(0, `rgba(255, 50, 50, ${attackGlow})`);
        gradient.addColorStop(1, 'rgba(255, 0, 0, 0)');
        ctx.fillStyle = gradient;
        ctx.beginPath();
        ctx.arc(x, y, glowRadius, 0, Math.PI * 2);
        ctx.fill();
      }
      // Draw signal glow (if signaling high or low and not attacking)
      else {
        const signalValue = signal || 0.5;
        const glowIntensity = signalValue * 0.6;

        if (Math.abs(signalValue - 0.5) > 0.1) {
          const glowColor = signalValue > 0.5
            ? `rgba(255, 200, 100, ${glowIntensity})` // warm glow for high signal
            : `rgba(100, 200, 255, ${glowIntensity})`; // cool glow for low signal
          const glowRadius = radius * (1.5 + signalValue);
          const gradient = ctx.createRadialGradient(x, y, radius, x, y, glowRadius);
          gradient.addColorStop(0, glowColor);
          gradient.addColorStop(1, 'rgba(0,0,0,0)');
          ctx.fillStyle = gradient;
          ctx.beginPath();
          ctx.arc(x, y, glowRadius, 0, Math.PI * 2);
          ctx.fill();
        }
      }

      // Energy determines saturation/lightness
      const energyRatio = Math.min(energy / 200, 1);
      const saturation = 50 + (energyRatio * 30);
      const lightness = 30 + (energyRatio * 25);

      // Draw agent body
      ctx.fillStyle = `hsl(${hue}, ${saturation}%, ${lightness}%)`;
      ctx.beginPath();
      ctx.arc(x, y, radius, 0, Math.PI * 2);
      ctx.fill();

      // Draw border for champions (top fitness) or the tracked champion
      if (isChampion) {
        ctx.strokeStyle = 'rgba(255, 215, 0, 1)'; // bright gold
        ctx.lineWidth = 3;
        ctx.stroke();
        // Draw crown icon above champion
        this.drawCrown(ctx, x, y - radius - 8);
      } else if (fitnessRatio > 0.8) {
        ctx.strokeStyle = 'rgba(255, 215, 0, 0.8)'; // gold
        ctx.lineWidth = 2;
        ctx.stroke();
      }

      // Draw direction indicator
      const dirLen = radius * 1.5;
      const dirX = x + Math.cos(direction) * dirLen;
      const dirY = y + Math.sin(direction) * dirLen;
      ctx.strokeStyle = `hsl(${hue}, ${saturation}%, ${lightness + 20}%)`;
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.moveTo(x, y);
      ctx.lineTo(dirX, dirY);
      ctx.stroke();

      // Draw energy bar
      const barWidth = radius * 2;
      const barHeight = 2;
      const barX = x - barWidth / 2;
      const barY = y - radius - 4;
      ctx.fillStyle = '#1a1a2e';
      ctx.fillRect(barX, barY, barWidth, barHeight);
      ctx.fillStyle = energy > 100 ? '#4ade80' : (energy > 50 ? '#facc15' : '#ef4444');
      ctx.fillRect(barX, barY, barWidth * energyRatio, barHeight);
    });

    // Draw stats overlay
    ctx.fillStyle = 'rgba(255, 255, 255, 0.8)';
    ctx.font = '11px monospace';
    ctx.fillText(`Agents: ${this.agents.length}`, 8, 16);
    ctx.fillText(`Food: ${this.food.length}`, 8, 30);
    ctx.fillStyle = 'rgba(255, 255, 255, 0.5)';
    ctx.fillText(`Max Gen: ${maxGen}`, 8, 44);

    // Count hunters and attackers
    const hunters = this.agents.filter(a => (a.kills || 0) > 0).length;
    const attacking = this.agents.filter(a => a.wants_attack).length;
    if (hunters > 0 || attacking > 0) {
      ctx.fillStyle = 'rgba(255, 100, 100, 0.8)';
      ctx.fillText(`Hunters: ${hunters} | Attacking: ${attacking}`, 8, 58);
    }

    // Draw event overlays
    this.drawEventOverlays(ctx, width, height, now);
  },

  // Draw a small crown icon
  drawCrown(ctx, x, y) {
    const size = 6;
    ctx.fillStyle = '#ffd700';
    ctx.beginPath();
    // Crown base
    ctx.moveTo(x - size, y + size/2);
    ctx.lineTo(x - size, y);
    ctx.lineTo(x - size/2, y + size/3);
    ctx.lineTo(x, y - size/2);
    ctx.lineTo(x + size/2, y + size/3);
    ctx.lineTo(x + size, y);
    ctx.lineTo(x + size, y + size/2);
    ctx.closePath();
    ctx.fill();
    // Crown jewels
    ctx.fillStyle = '#ff4444';
    ctx.beginPath();
    ctx.arc(x, y - size/4, 1.5, 0, Math.PI * 2);
    ctx.fill();
  },

  // Draw event notification overlays
  drawEventOverlays(ctx, width, height, now) {
    if (this.events.length === 0) return;

    let yOffset = height - 30;

    this.events.forEach(event => {
      const elapsed = now - event.startTime;
      const duration = event.endTime - event.startTime;
      const progress = elapsed / duration;
      const alpha = Math.max(0, 1 - progress);

      let text = '';
      let color = 'rgba(255, 255, 255, ' + alpha + ')';
      let bgColor = 'rgba(0, 0, 0, 0.6)';

      switch (event.type) {
        case 'champion':
          text = `🏆 New Champion! Fitness: ${Math.round(event.data.fitness || 0)}`;
          color = `rgba(255, 215, 0, ${alpha})`;
          bgColor = `rgba(50, 40, 0, ${alpha * 0.8})`;
          break;
        case 'speciation':
          text = `🧬 New Species Emerged!`;
          color = `rgba(138, 43, 226, ${alpha})`;
          bgColor = `rgba(30, 10, 50, ${alpha * 0.8})`;
          break;
        case 'extinction':
          text = `💀 Species Extinct`;
          color = `rgba(255, 100, 100, ${alpha})`;
          bgColor = `rgba(50, 10, 10, ${alpha * 0.8})`;
          break;
        default:
          text = event.type;
      }

      // Draw notification box
      ctx.font = '12px monospace';
      const textWidth = ctx.measureText(text).width;
      const boxX = width - textWidth - 20;
      const boxY = yOffset - 16;

      ctx.fillStyle = bgColor;
      ctx.fillRect(boxX - 8, boxY - 4, textWidth + 16, 24);

      ctx.fillStyle = color;
      ctx.fillText(text, boxX, yOffset);

      yOffset -= 30;
    });
  }
};
