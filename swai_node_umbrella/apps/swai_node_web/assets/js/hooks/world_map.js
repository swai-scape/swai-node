/**
 * WorldMap Hook
 *
 * Renders agents on a Leaflet OpenStreetMap background.
 * Uses canvas overlay for high-performance agent rendering.
 * Agents have lat/lon coordinates and spread across the real world.
 */

import L from 'leaflet';
// CSS loaded via CDN in root.html.heex to avoid esbuild asset issues

// Agent size in meters (1m diameter = 0.5m radius)
const AGENT_RADIUS_METERS = 0.5;
const FOOD_RADIUS_METERS = 0.3;
const EVENT_DURATION_MS = 3000;

// Signal threshold for audio
const SIGNAL_THRESHOLD = 0.7;
const MAX_SIMULTANEOUS_SOUNDS = 6;
const NOTE_DURATION = 0.15;
const BASE_FREQ = 220;
const FREQ_RANGE = 440;

export const WorldMap = {
  mounted() {
    // Get geo config from data attributes
    this.centerLon = parseFloat(this.el.dataset.longitude) || 4.9041;
    this.centerLat = parseFloat(this.el.dataset.latitude) || 52.3676;
    this.defaultZoom = parseInt(this.el.dataset.zoom) || 4;

    // Initialize state
    this.agents = [];
    this.food = [];
    this.events = [];
    this.championId = null;

    // Audio state
    this.audioCtx = null;
    this.audioEnabled = false;
    this.activeSounds = 0;
    this.lastSoundTime = {};

    // Initialize Leaflet map
    this.initMap();

    // Handle world updates from server
    this.handleEvent("world_update", (payload) => {
      this.agents = payload.agents || [];
      this.food = payload.food || [];
      this.renderAgents();
    });

    // Handle evolution events
    this.handleEvent("evolution_event", (payload) => {
      const now = Date.now();
      this.events.push({
        type: payload.type,
        data: payload.data || {},
        startTime: now,
        endTime: now + EVENT_DURATION_MS
      });

      if (payload.type === 'champion' && payload.data?.agent_id) {
        this.championId = payload.data.agent_id;
      }

      this.renderAgents();
    });

    // Handle audio toggle
    this.handleEvent("toggle_audio", (payload) => {
      this.audioEnabled = payload.enabled;
      if (this.audioEnabled && !this.audioCtx) {
        this.initAudio();
      }
    });
  },

  initMap() {
    // Create the Leaflet map
    this.map = L.map(this.el, {
      center: [this.centerLat, this.centerLon],
      zoom: this.defaultZoom,
      zoomControl: true,
      attributionControl: true
    });

    // Add OpenStreetMap tiles with dark theme
    L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png', {
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors &copy; <a href="https://carto.com/attributions">CARTO</a>',
      subdomains: 'abcd',
      maxZoom: 19
    }).addTo(this.map);

    // Create canvas overlay for agents
    this.canvasLayer = L.canvas({ padding: 0.5 });

    // Create a custom pane for the canvas overlay
    this.map.createPane('agentPane');
    this.map.getPane('agentPane').style.zIndex = 650;

    // Create canvas element for agent rendering
    this.setupCanvasOverlay();

    // Re-render on map move/zoom
    this.map.on('moveend', () => this.renderAgents());
    this.map.on('zoomend', () => this.renderAgents());

    // Initial render
    this.renderAgents();
  },

  setupCanvasOverlay() {
    // Create a canvas element that overlays the map
    this.canvas = document.createElement('canvas');
    this.canvas.style.position = 'absolute';
    this.canvas.style.top = '0';
    this.canvas.style.left = '0';
    this.canvas.style.pointerEvents = 'none';
    this.canvas.style.zIndex = '650';

    // Add to map container
    this.map.getContainer().appendChild(this.canvas);
    this.ctx = this.canvas.getContext('2d');

    // Size canvas to map
    this.resizeCanvas();

    // Resize on container resize
    const resizeObserver = new ResizeObserver(() => this.resizeCanvas());
    resizeObserver.observe(this.map.getContainer());
    this.resizeObserver = resizeObserver;
  },

  resizeCanvas() {
    const container = this.map.getContainer();
    this.canvas.width = container.clientWidth;
    this.canvas.height = container.clientHeight;
    // Tell Leaflet that container size changed
    this.map.invalidateSize();
    this.renderAgents();
  },

  // Convert lat/lon to canvas pixel coordinates
  latLonToPixel(lat, lon) {
    const point = this.map.latLngToContainerPoint([lat, lon]);
    return { x: point.x, y: point.y };
  },

  // Convert pixel coordinates to lat/lon
  // Agents originate from node location, 1 pixel = 1 meter
  // World coordinates: x=0-800, y=0-600 (center = 400, 300)
  pixelToLatLon(x, y, width = 800, height = 600) {
    // Center of world in pixels
    const centerX = width / 2;
    const centerY = height / 2;

    // Offset from center in pixels (= meters)
    const offsetX = x - centerX;  // positive = east
    const offsetY = centerY - y;  // positive = north (y is inverted)

    // Convert meters to degrees
    // 1 degree latitude ≈ 111,320 meters
    // 1 degree longitude ≈ 111,320 * cos(latitude) meters
    const metersPerDegreeLat = 111320;
    const metersPerDegreeLon = 111320 * Math.cos(this.centerLat * Math.PI / 180);

    const lat = this.centerLat + (offsetY / metersPerDegreeLat);
    const lon = this.centerLon + (offsetX / metersPerDegreeLon);

    return { lat, lon };
  },

  // Calculate how many screen pixels represent 1 meter at current zoom
  metersToPixels(meters) {
    const zoom = this.map.getZoom();
    // At zoom 0, 1 pixel ≈ 156543 meters at equator
    // Scale by cos(lat) for latitude and 2^zoom for zoom level
    const metersPerPixel = 156543.03 * Math.cos(this.centerLat * Math.PI / 180) / Math.pow(2, zoom);
    return meters / metersPerPixel;
  },

  renderAgents() {
    if (!this.ctx || !this.map) return;

    const ctx = this.ctx;
    const width = this.canvas.width;
    const height = this.canvas.height;
    const now = Date.now();

    // Clean up expired events
    this.events = this.events.filter(e => e.endTime > now);

    // Clear canvas
    ctx.clearRect(0, 0, width, height);

    // Calculate pixel size of 1 meter at current zoom
    const pixelsPerMeter = this.metersToPixels(1);

    // Draw food as squares with glow
    this.food.forEach(food => {
      const coords = this.getFoodCoords(food);
      if (!coords) return;

      const pixel = this.latLonToPixel(coords.lat, coords.lon);
      if (this.isOffScreen(pixel, width, height)) return;

      const size = Math.max(4, FOOD_RADIUS_METERS * pixelsPerMeter * 1.5);
      const energy = food.energy || 20;
      const energyRatio = Math.min(energy / 30, 1);

      // Glow effect (intensity based on energy)
      const glowSize = size * 2;
      const gradient = ctx.createRadialGradient(pixel.x, pixel.y, 0, pixel.x, pixel.y, glowSize);
      gradient.addColorStop(0, `rgba(74, 222, 128, ${0.4 + energyRatio * 0.4})`);
      gradient.addColorStop(1, 'rgba(74, 222, 128, 0)');
      ctx.fillStyle = gradient;
      ctx.fillRect(pixel.x - glowSize, pixel.y - glowSize, glowSize * 2, glowSize * 2);

      // Food square with rounded corners
      ctx.fillStyle = `hsl(142, ${60 + energyRatio * 20}%, ${45 + energyRatio * 15}%)`;
      this.drawRoundedRect(ctx, pixel.x - size/2, pixel.y - size/2, size, size, 2);

      // Inner highlight
      ctx.fillStyle = 'rgba(255,255,255,0.3)';
      this.drawRoundedRect(ctx, pixel.x - size/4, pixel.y - size/2 + 1, size/2, size/4, 1);
    });

    // Find max values for normalization
    const maxGen = Math.max(1, ...this.agents.map(a => a.generation || 0));

    // Draw agents with shape based on behavior
    this.agents.forEach(agent => {
      const coords = this.getAgentCoords(agent);
      if (!coords) return;

      const pixel = this.latLonToPixel(coords.lat, coords.lon);
      if (this.isOffScreen(pixel, width, height)) return;

      const { direction, energy, generation, signal, wants_attack, kills, id, food_eaten } = agent;
      const killCount = kills || 0;
      const foodCount = food_eaten || 0;

      // Determine behavior type
      const behaviorType = this.getBehaviorType(killCount, foodCount);

      // Size based on energy (min 4px, max 12px)
      const energyRatio = Math.min((energy || 50) / 150, 1);
      const baseSize = Math.max(4, AGENT_RADIUS_METERS * pixelsPerMeter);
      const size = baseSize * (0.7 + energyRatio * 0.6);

      const isChampion = this.championId && id === this.championId;

      // Generation determines HUE (purple -> cyan -> green)
      const genRatio = (generation || 0) / maxGen;
      let hue = 280 - (genRatio * 160); // 280 (purple) -> 120 (green)

      // Carnivores shift toward red/orange
      if (behaviorType === 'carnivore') {
        hue = 0 + (genRatio * 30); // Red to orange
      } else if (behaviorType === 'omnivore') {
        hue = 45 + (genRatio * 30); // Orange to yellow
      }

      const saturation = 60 + (energyRatio * 25);
      const lightness = 35 + (energyRatio * 20);
      const color = `hsl(${hue}, ${saturation}%, ${lightness}%)`;

      // === DECORATORS (drawn first, behind agent) ===

      // Champion golden aura
      if (isChampion) {
        this.drawChampionAura(ctx, pixel.x, pixel.y, size, now);
      }

      // Attack glow (pulsing red)
      if (wants_attack) {
        this.drawAttackGlow(ctx, pixel.x, pixel.y, size, now);
      }
      // Signal aura (communication)
      else if (signal !== undefined && Math.abs(signal - 0.5) > 0.15) {
        this.drawSignalAura(ctx, pixel.x, pixel.y, size, signal);
      }

      // Energy ring (shows health)
      this.drawEnergyRing(ctx, pixel.x, pixel.y, size, energyRatio);

      // === AGENT BODY (shape by behavior) ===
      ctx.fillStyle = color;
      ctx.strokeStyle = `hsl(${hue}, ${saturation}%, ${lightness - 15}%)`;
      ctx.lineWidth = 1;

      if (behaviorType === 'carnivore') {
        // Triangle pointing in direction (predator)
        this.drawTriangle(ctx, pixel.x, pixel.y, size, direction);
      } else if (behaviorType === 'omnivore') {
        // Diamond shape (adaptable)
        this.drawDiamond(ctx, pixel.x, pixel.y, size, direction);
      } else {
        // Circle (peaceful herbivore)
        this.drawCircle(ctx, pixel.x, pixel.y, size);
      }

      // === TOP DECORATORS ===

      // Champion crown
      if (isChampion) {
        this.drawCrown(ctx, pixel.x, pixel.y - size - 3, size * 0.8);
      }

      // Direction indicator (small line)
      this.drawDirectionIndicator(ctx, pixel.x, pixel.y, size, direction, color);

      // Kill count badge (for hunters)
      if (killCount > 0) {
        this.drawKillBadge(ctx, pixel.x + size, pixel.y - size, killCount);
      }
    });

    // Draw minimal stats overlay (top-left, under zoom controls)
    const zoom = this.map.getZoom();
    ctx.fillStyle = 'rgba(0, 0, 0, 0.5)';
    ctx.fillRect(8, 95, 85, 28);
    ctx.fillStyle = 'rgba(255, 255, 255, 0.8)';
    ctx.font = '10px monospace';
    ctx.fillText(`${this.agents.length} agents`, 12, 108);
    ctx.fillText(`${this.food.length} food`, 12, 120);

    // Draw node location marker
    this.drawNodeMarker(ctx, width, height);

    // Draw event overlays
    this.drawEventOverlays(ctx, width, height, now);
  },

  drawNodeMarker(ctx, width, height) {
    // Draw a marker at the node's home location
    const pixel = this.latLonToPixel(this.centerLat, this.centerLon);

    if (pixel.x >= 0 && pixel.x <= width && pixel.y >= 0 && pixel.y <= height) {
      // Outer ring
      ctx.strokeStyle = 'rgba(138, 43, 226, 0.8)';
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.arc(pixel.x, pixel.y, 15, 0, Math.PI * 2);
      ctx.stroke();

      // Inner dot
      ctx.fillStyle = 'rgba(138, 43, 226, 0.6)';
      ctx.beginPath();
      ctx.arc(pixel.x, pixel.y, 5, 0, Math.PI * 2);
      ctx.fill();

      // Label
      ctx.fillStyle = 'rgba(255, 255, 255, 0.8)';
      ctx.font = '10px sans-serif';
      ctx.fillText('NODE', pixel.x - 15, pixel.y + 28);
    }
  },

  drawCrown(ctx, x, y, agentRadius) {
    const size = Math.max(3, agentRadius);
    ctx.fillStyle = '#ffd700';
    ctx.beginPath();
    ctx.moveTo(x - size, y + size/2);
    ctx.lineTo(x - size, y);
    ctx.lineTo(x - size/2, y + size/3);
    ctx.lineTo(x, y - size/2);
    ctx.lineTo(x + size/2, y + size/3);
    ctx.lineTo(x + size, y);
    ctx.lineTo(x + size, y + size/2);
    ctx.closePath();
    ctx.fill();
  },

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
          text = `New Champion! Fitness: ${Math.round(event.data.fitness || 0)}`;
          color = `rgba(255, 215, 0, ${alpha})`;
          bgColor = `rgba(50, 40, 0, ${alpha * 0.8})`;
          break;
        case 'speciation':
          text = `New Species Emerged!`;
          color = `rgba(138, 43, 226, ${alpha})`;
          bgColor = `rgba(30, 10, 50, ${alpha * 0.8})`;
          break;
        default:
          text = event.type;
      }

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
  },

  // Audio functions (same as WorldCanvas)
  initAudio() {
    try {
      this.audioCtx = new (window.AudioContext || window.webkitAudioContext)();
      this.masterGain = this.audioCtx.createGain();
      this.masterGain.gain.value = 0.3;
      this.masterGain.connect(this.audioCtx.destination);
    } catch (e) {
      console.warn('Web Audio API not supported:', e);
      this.audioEnabled = false;
    }
  },

  sonifySignals() {
    if (!this.audioEnabled || !this.audioCtx) return;
    if (this.audioCtx.state === 'suspended') {
      this.audioCtx.resume();
    }

    const now = Date.now();
    const maxGen = Math.max(1, ...this.agents.map(a => a.generation || 0));

    const signalingAgents = this.agents
      .filter(a => (a.signal || 0) > SIGNAL_THRESHOLD)
      .filter(a => {
        const lastTime = this.lastSoundTime[a.id] || 0;
        return (now - lastTime) > 200;
      })
      .slice(0, MAX_SIMULTANEOUS_SOUNDS - this.activeSounds);

    signalingAgents.forEach(agent => {
      this.playSignalTone(agent, maxGen);
      this.lastSoundTime[agent.id] = now;
    });
  },

  playSignalTone(agent, maxGen) {
    if (this.activeSounds >= MAX_SIMULTANEOUS_SOUNDS) return;

    const ctx = this.audioCtx;
    const now = ctx.currentTime;

    const genRatio = (agent.generation || 0) / maxGen;
    const freq = BASE_FREQ + (genRatio * FREQ_RANGE);
    const volume = Math.min(0.5, (agent.signal - SIGNAL_THRESHOLD) * 2);

    const osc = ctx.createOscillator();
    osc.type = 'sine';
    osc.frequency.setValueAtTime(freq, now);

    const gainNode = ctx.createGain();
    gainNode.gain.setValueAtTime(0, now);
    gainNode.gain.linearRampToValueAtTime(volume, now + 0.01);
    gainNode.gain.exponentialRampToValueAtTime(0.001, now + NOTE_DURATION);

    osc.connect(gainNode);
    gainNode.connect(this.masterGain);

    this.activeSounds++;
    osc.start(now);
    osc.stop(now + NOTE_DURATION);

    osc.onended = () => {
      this.activeSounds--;
      osc.disconnect();
      gainNode.disconnect();
    };
  },

  // ==========================================================================
  // Helper: Coordinate conversion
  // ==========================================================================

  getFoodCoords(food) {
    // Use lat/lon directly from backend - no conversion needed
    if (food.lat !== undefined && food.lon !== undefined) {
      return { lat: food.lat, lon: food.lon };
    }
    // Fallback for legacy data
    console.warn('Food missing lat/lon, using fallback conversion');
    return this.pixelToLatLon(food.x, food.y);
  },

  getAgentCoords(agent) {
    // Use lat/lon directly from backend - no conversion needed
    if (agent.lat !== undefined && agent.lon !== undefined) {
      return { lat: agent.lat, lon: agent.lon };
    }
    // Fallback for legacy data
    console.warn('Agent missing lat/lon, using fallback conversion');
    return this.pixelToLatLon(agent.x, agent.y);
  },

  isOffScreen(pixel, width, height) {
    return pixel.x < -50 || pixel.x > width + 50 || pixel.y < -50 || pixel.y > height + 50;
  },

  // ==========================================================================
  // Helper: Behavior type detection
  // ==========================================================================

  getBehaviorType(kills, foodEaten) {
    if (kills > 0 && kills >= foodEaten * 0.5) return 'carnivore';
    if (kills > 0) return 'omnivore';
    return 'herbivore';
  },

  // ==========================================================================
  // Drawing: Shapes
  // ==========================================================================

  drawCircle(ctx, x, y, size) {
    ctx.beginPath();
    ctx.arc(x, y, size, 0, Math.PI * 2);
    ctx.fill();
    ctx.stroke();
  },

  drawTriangle(ctx, x, y, size, direction) {
    ctx.save();
    ctx.translate(x, y);
    ctx.rotate(direction);
    ctx.beginPath();
    ctx.moveTo(size * 1.2, 0);  // Point
    ctx.lineTo(-size * 0.8, -size * 0.8);
    ctx.lineTo(-size * 0.8, size * 0.8);
    ctx.closePath();
    ctx.fill();
    ctx.stroke();
    ctx.restore();
  },

  drawDiamond(ctx, x, y, size, direction) {
    ctx.save();
    ctx.translate(x, y);
    ctx.rotate(direction + Math.PI / 4);
    ctx.beginPath();
    ctx.rect(-size * 0.7, -size * 0.7, size * 1.4, size * 1.4);
    ctx.fill();
    ctx.stroke();
    ctx.restore();
  },

  drawRoundedRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.lineTo(x + w - r, y);
    ctx.quadraticCurveTo(x + w, y, x + w, y + r);
    ctx.lineTo(x + w, y + h - r);
    ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
    ctx.lineTo(x + r, y + h);
    ctx.quadraticCurveTo(x, y + h, x, y + h - r);
    ctx.lineTo(x, y + r);
    ctx.quadraticCurveTo(x, y, x + r, y);
    ctx.closePath();
    ctx.fill();
  },

  // ==========================================================================
  // Drawing: Decorators
  // ==========================================================================

  drawEnergyRing(ctx, x, y, size, energyRatio) {
    // Outer ring showing energy level
    const ringRadius = size + 2;
    const startAngle = -Math.PI / 2;
    const endAngle = startAngle + (Math.PI * 2 * energyRatio);

    ctx.strokeStyle = `hsla(${120 * energyRatio}, 70%, 50%, 0.6)`;
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.arc(x, y, ringRadius, startAngle, endAngle);
    ctx.stroke();
  },

  drawChampionAura(ctx, x, y, size, now) {
    const pulsePhase = (now % 1000) / 1000;
    const pulseSize = 1 + Math.sin(pulsePhase * Math.PI * 2) * 0.3;
    const auraRadius = size * 3 * pulseSize;

    const gradient = ctx.createRadialGradient(x, y, size, x, y, auraRadius);
    gradient.addColorStop(0, 'rgba(255, 215, 0, 0.5)');
    gradient.addColorStop(0.5, 'rgba(255, 180, 0, 0.2)');
    gradient.addColorStop(1, 'rgba(255, 215, 0, 0)');

    ctx.fillStyle = gradient;
    ctx.beginPath();
    ctx.arc(x, y, auraRadius, 0, Math.PI * 2);
    ctx.fill();
  },

  drawAttackGlow(ctx, x, y, size, now) {
    const pulsePhase = (now % 300) / 300;
    const intensity = 0.5 + Math.sin(pulsePhase * Math.PI * 2) * 0.3;
    const glowRadius = size * 2.5;

    const gradient = ctx.createRadialGradient(x, y, size * 0.5, x, y, glowRadius);
    gradient.addColorStop(0, `rgba(255, 50, 50, ${intensity})`);
    gradient.addColorStop(1, 'rgba(255, 0, 0, 0)');

    ctx.fillStyle = gradient;
    ctx.beginPath();
    ctx.arc(x, y, glowRadius, 0, Math.PI * 2);
    ctx.fill();
  },

  drawSignalAura(ctx, x, y, size, signal) {
    const intensity = Math.abs(signal - 0.5) * 1.2;
    const isHigh = signal > 0.5;
    const color = isHigh ? `rgba(255, 200, 100, ${intensity})` : `rgba(100, 200, 255, ${intensity})`;
    const glowRadius = size * (1.5 + intensity);

    const gradient = ctx.createRadialGradient(x, y, size * 0.5, x, y, glowRadius);
    gradient.addColorStop(0, color);
    gradient.addColorStop(1, 'rgba(0,0,0,0)');

    ctx.fillStyle = gradient;
    ctx.beginPath();
    ctx.arc(x, y, glowRadius, 0, Math.PI * 2);
    ctx.fill();
  },

  drawDirectionIndicator(ctx, x, y, size, direction, color) {
    const len = size * 0.8;
    const endX = x + Math.cos(direction) * (size + len);
    const endY = y + Math.sin(direction) * (size + len);

    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(x + Math.cos(direction) * size, y + Math.sin(direction) * size);
    ctx.lineTo(endX, endY);
    ctx.stroke();
  },

  drawKillBadge(ctx, x, y, count) {
    const badgeSize = 6;
    ctx.fillStyle = '#ef4444';
    ctx.beginPath();
    ctx.arc(x, y, badgeSize, 0, Math.PI * 2);
    ctx.fill();

    ctx.fillStyle = 'white';
    ctx.font = 'bold 8px sans-serif';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(count > 9 ? '9+' : count.toString(), x, y);
    ctx.textAlign = 'start';
    ctx.textBaseline = 'alphabetic';
  },

  destroyed() {
    if (this.map) {
      this.map.remove();
    }
    if (this.resizeObserver) {
      this.resizeObserver.disconnect();
    }
    if (this.canvas && this.canvas.parentNode) {
      this.canvas.parentNode.removeChild(this.canvas);
    }
  }
};
