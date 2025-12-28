# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

# Configure Mix tasks and generators
config :swai_node,
  ecto_repos: [SwaiNode.Repo]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :swai_node, SwaiNode.Mailer, adapter: Swoosh.Adapters.Local

config :swai_node_web,
  ecto_repos: [SwaiNode.Repo],
  generators: [context_app: :swai_node]

# Configures the endpoint
config :swai_node_web, SwaiNodeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SwaiNodeWeb.ErrorHTML, json: SwaiNodeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SwaiNode.PubSub,
  live_view: [signing_salt: "lIe8RFAR"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  swai_node_web: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/swai_node_web/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  swai_node_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/swai_node_web", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# =============================================================================
# Macula HTTP/3 Mesh Platform Configuration
# =============================================================================
# Swai-node runs as an "edge" peer in the macula mesh.
# Edge nodes connect to bootstrap nodes for DHT/service discovery
# but communicate directly with other peers via QUIC.

config :macula,
  # Edge mode: pure P2P peer (no gateway)
  mode: :edge,
  start_gateway: false,
  # DHT configuration (Kademlia parameters)
  dht_k: 20,
  dht_alpha: 3,
  # RPC configuration
  rpc_timeout: 5000,
  rpc_max_hops: 10,
  # Pub/Sub configuration
  pubsub_max_hops: 10,
  pubsub_qos: 0,
  # TLS mode (development uses self-signed certs)
  tls_mode: :development

# =============================================================================
# Geographic Configuration (World Map)
# =============================================================================
# Each node has a geographic location where its agents originate.
# Coordinates are in WGS84 (standard GPS coordinates).

config :swai_node, :geo,
  # Node's geographic location (Gniezno, Poland - ul. Św. Michała 25)
  longitude: 17.5828,
  latitude: 52.5347,
  # Map zoom level (higher = more zoomed in, 16 = ~800m visible)
  default_zoom: 16,
  # Road network radius in meters (fetched from OpenStreetMap)
  road_network_radius_m: 500,
  # Auto-load road network on startup
  auto_load_roads: true

# =============================================================================
# erl_esdb - BEAM-native Event Store
# =============================================================================
# Local event store for CQRS/Event Sourcing.
# Uses Khepri/Ra under the hood for Raft consensus.

config :erl_esdb,
  stores: [],
  default_timeout: 5000,
  writer_pool_size: 5,
  reader_pool_size: 5

# =============================================================================
# Neuroevolution Configuration
# =============================================================================
# macula_neuroevolution and macula_tweann provide the AI warrior evolution.

config :macula_tweann,
  # Use LTC neurons for temporal dynamics
  default_neuron_type: :ltc,
  # Enable NIF acceleration when available
  use_nifs: true

config :macula_neuroevolution,
  # Default population size
  population_size: 100,
  # Evolution parameters
  mutation_rate: 0.1,
  crossover_rate: 0.7

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
