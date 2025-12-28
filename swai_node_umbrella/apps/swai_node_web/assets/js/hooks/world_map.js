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
      this.sonifySignals();
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

    // Draw food
    this.food.forEach(food => {
      let lat, lon;

      // Check if food has lat/lon or needs conversion from x/y
      if (food.lat !== undefined && food.lon !== undefined) {
        lat = food.lat;
        lon = food.lon;
      } else {
        const coords = this.pixelToLatLon(food.x, food.y);
        lat = coords.lat;
        lon = coords.lon;
      }

      const pixel = this.latLonToPixel(lat, lon);

      // Skip if off-screen
      if (pixel.x < -50 || pixel.x > width + 50 || pixel.y < -50 || pixel.y > height + 50) {
        return;
      }

      // Food radius in pixels (minimum 2px for visibility)
      const radius = Math.max(2, FOOD_RADIUS_METERS * pixelsPerMeter);

      // Glow effect
      const gradient = ctx.createRadialGradient(pixel.x, pixel.y, 0, pixel.x, pixel.y, radius * 2);
      gradient.addColorStop(0, 'rgba(74, 222, 128, 0.8)');
      gradient.addColorStop(1, 'rgba(74, 222, 128, 0)');
      ctx.fillStyle = gradient;
      ctx.beginPath();
      ctx.arc(pixel.x, pixel.y, radius * 2, 0, Math.PI * 2);
      ctx.fill();

      // Core
      ctx.fillStyle = '#4ade80';
      ctx.beginPath();
      ctx.arc(pixel.x, pixel.y, radius, 0, Math.PI * 2);
      ctx.fill();
    });

    // Find max generation for normalization
    const maxGen = Math.max(1, ...this.agents.map(a => a.generation || 0));
    const maxFitness = Math.max(1, ...this.agents.map(a => a.fitness || 0));

    // Draw agents
    this.agents.forEach(agent => {
      let lat, lon;

      // Check if agent has lat/lon or needs conversion from x/y
      if (agent.lat !== undefined && agent.lon !== undefined) {
        lat = agent.lat;
        lon = agent.lon;
      } else {
        const coords = this.pixelToLatLon(agent.x, agent.y);
        lat = coords.lat;
        lon = coords.lon;
      }

      const pixel = this.latLonToPixel(lat, lon);

      // Skip if off-screen
      if (pixel.x < -50 || pixel.x > width + 50 || pixel.y < -50 || pixel.y > height + 50) {
        return;
      }

      const { direction, energy, fitness, generation, signal, wants_attack, kills, id } = agent;

      const isChampion = this.championId && id === this.championId;

      // Generation determines HUE
      const genRatio = (generation || 0) / maxGen;
      let hue = 270 - (genRatio * 180);

      // Hunters shift toward red
      const killCount = kills || 0;
      if (killCount > 0) {
        hue = Math.max(0, hue - (killCount * 30));
      }

      // Agent radius: 0.5m base, minimum 2px for visibility
      const radius = Math.max(2, AGENT_RADIUS_METERS * pixelsPerMeter);

      // Champion golden aura
      if (isChampion) {
        const pulsePhase = (now % 1000) / 1000;
        const pulseSize = 1 + Math.sin(pulsePhase * Math.PI * 2) * 0.3;
        const auraRadius = radius * 3 * pulseSize;
        const gradient = ctx.createRadialGradient(pixel.x, pixel.y, radius, pixel.x, pixel.y, auraRadius);
        gradient.addColorStop(0, 'rgba(255, 215, 0, 0.6)');
        gradient.addColorStop(0.5, 'rgba(255, 180, 0, 0.3)');
        gradient.addColorStop(1, 'rgba(255, 215, 0, 0)');
        ctx.fillStyle = gradient;
        ctx.beginPath();
        ctx.arc(pixel.x, pixel.y, auraRadius, 0, Math.PI * 2);
        ctx.fill();
      }

      // Attack glow
      if (wants_attack) {
        const glowRadius = radius * 2.5;
        const gradient = ctx.createRadialGradient(pixel.x, pixel.y, radius, pixel.x, pixel.y, glowRadius);
        gradient.addColorStop(0, 'rgba(255, 50, 50, 0.7)');
        gradient.addColorStop(1, 'rgba(255, 0, 0, 0)');
        ctx.fillStyle = gradient;
        ctx.beginPath();
        ctx.arc(pixel.x, pixel.y, glowRadius, 0, Math.PI * 2);
        ctx.fill();
      } else {
        // Signal glow
        const signalValue = signal || 0.5;
        if (Math.abs(signalValue - 0.5) > 0.1) {
          const glowIntensity = signalValue * 0.6;
          const glowColor = signalValue > 0.5
            ? `rgba(255, 200, 100, ${glowIntensity})`
            : `rgba(100, 200, 255, ${glowIntensity})`;
          const glowRadius = radius * (1.5 + signalValue);
          const gradient = ctx.createRadialGradient(pixel.x, pixel.y, radius, pixel.x, pixel.y, glowRadius);
          gradient.addColorStop(0, glowColor);
          gradient.addColorStop(1, 'rgba(0,0,0,0)');
          ctx.fillStyle = gradient;
          ctx.beginPath();
          ctx.arc(pixel.x, pixel.y, glowRadius, 0, Math.PI * 2);
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
      ctx.arc(pixel.x, pixel.y, radius, 0, Math.PI * 2);
      ctx.fill();

      // Champion border
      if (isChampion) {
        ctx.strokeStyle = 'rgba(255, 215, 0, 1)';
        ctx.lineWidth = 2;
        ctx.stroke();
        this.drawCrown(ctx, pixel.x, pixel.y - radius - 4, radius);
      }

      // Direction indicator
      const dirLen = radius * 1.5;
      const dirX = pixel.x + Math.cos(direction) * dirLen;
      const dirY = pixel.y + Math.sin(direction) * dirLen;
      ctx.strokeStyle = `hsl(${hue}, ${saturation}%, ${lightness + 20}%)`;
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.moveTo(pixel.x, pixel.y);
      ctx.lineTo(dirX, dirY);
      ctx.stroke();
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
