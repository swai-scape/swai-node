/**
 * ECharts LiveView Hook
 *
 * Generic hook for rendering Apache ECharts visualizations in Phoenix LiveView.
 *
 * Usage in HEEx:
 *   <div
 *     id="my-chart"
 *     phx-hook="EChartsHook"
 *     phx-update="ignore"
 *     data-options={Jason.encode!(@chart_options)}
 *     class="h-64 w-full"
 *   />
 */
import * as echarts from 'echarts';

// Dark theme configuration matching SwaiNode UI
const darkTheme = {
  backgroundColor: 'transparent',
  textStyle: {
    color: '#e5e7eb'  // gray-200
  },
  title: {
    textStyle: {
      color: '#f3f4f6'  // gray-100
    },
    subtextStyle: {
      color: '#9ca3af'  // gray-400
    }
  },
  legend: {
    textStyle: {
      color: '#d1d5db'  // gray-300
    }
  },
  tooltip: {
    backgroundColor: 'rgba(17, 24, 39, 0.9)',  // gray-900 with alpha
    borderColor: '#374151',  // gray-700
    textStyle: {
      color: '#f3f4f6'  // gray-100
    }
  },
  xAxis: {
    axisLine: {
      lineStyle: {
        color: '#4b5563'  // gray-600
      }
    },
    axisLabel: {
      color: '#9ca3af'  // gray-400
    },
    splitLine: {
      lineStyle: {
        color: '#374151'  // gray-700
      }
    }
  },
  yAxis: {
    axisLine: {
      lineStyle: {
        color: '#4b5563'  // gray-600
      }
    },
    axisLabel: {
      color: '#9ca3af'  // gray-400
    },
    splitLine: {
      lineStyle: {
        color: '#374151'  // gray-700
      }
    }
  },
  // Color palette for series
  color: [
    '#eab308',  // yellow-500 (best fitness)
    '#22c55e',  // green-500 (avg fitness / herbivore)
    '#f59e0b',  // amber-500 (omnivore)
    '#ef4444',  // red-500 (carnivore)
    '#8b5cf6',  // violet-500
    '#3b82f6',  // blue-500
  ]
};

// Register the dark theme
echarts.registerTheme('swai-dark', darkTheme);

export const EChartsHook = {
  mounted() {
    // Initialize chart with dark theme
    this.chart = echarts.init(this.el, 'swai-dark', {
      renderer: 'canvas'  // canvas is faster for real-time updates
    });

    // Parse and apply initial options
    this.applyOptions();

    // Handle window resize
    this.resizeHandler = () => {
      if (this.chart) {
        this.chart.resize();
      }
    };
    window.addEventListener('resize', this.resizeHandler);

    // Use ResizeObserver for container size changes
    if (typeof ResizeObserver !== 'undefined') {
      this.resizeObserver = new ResizeObserver((entries) => {
        for (const entry of entries) {
          if (entry.contentRect.width > 0 && entry.contentRect.height > 0) {
            if (this.chart) {
              this.chart.resize();
            }
          }
        }
      });
      this.resizeObserver.observe(this.el);
    }

    // Trigger resize after short delay for initial render
    setTimeout(() => {
      if (this.chart && this.el.offsetWidth > 0 && this.el.offsetHeight > 0) {
        this.chart.resize();
      }
    }, 100);

    // Listen for real-time updates from the server
    const eventName = `update-chart-${this.el.id}`;
    this.handleEvent(eventName, ({ options }) => {
      if (this.chart && options) {
        this.chart.setOption(options, { notMerge: false, lazyUpdate: true });
      }
    });

    // Generic update-chart event
    this.handleEvent("update-chart", ({ id, options }) => {
      if (this.chart && id === this.el.id && options) {
        this.chart.setOption(options, { notMerge: false, lazyUpdate: true });
      }
    });
  },

  updated() {
    this.applyOptions();
  },

  destroyed() {
    window.removeEventListener('resize', this.resizeHandler);
    if (this.resizeObserver) {
      this.resizeObserver.disconnect();
      this.resizeObserver = null;
    }
    if (this.chart) {
      this.chart.dispose();
      this.chart = null;
    }
  },

  applyOptions() {
    const optionsJson = this.el.dataset.options;
    if (optionsJson && this.chart) {
      try {
        const options = JSON.parse(optionsJson);
        this.chart.setOption(options, { notMerge: true });
      } catch (e) {
        console.error('EChartsHook: Failed to parse options JSON:', e);
      }
    }
  }
};

export default EChartsHook;
