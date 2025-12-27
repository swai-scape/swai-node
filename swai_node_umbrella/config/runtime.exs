import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

config :swai_node_web, SwaiNodeWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# =============================================================================
# Macula Mesh Runtime Configuration
# =============================================================================
# Environment variables for macula mesh connectivity.

# Parse bootstrap nodes from comma-separated string
bootstrap_nodes =
  case System.get_env("MACULA_BOOTSTRAP_NODES") do
    nil -> []
    "" -> []
    nodes -> String.split(nodes, ",", trim: true)
  end

if bootstrap_nodes != [] do
  config :macula, bootstrap_nodes: bootstrap_nodes
end

if realm = System.get_env("MACULA_REALM") do
  config :macula, realm: realm
end

if tls_mode = System.get_env("MACULA_TLS_MODE") do
  config :macula, tls_mode: String.to_atom(tls_mode)
end

# Node identity (used for peer identification in mesh)
if node_id = System.get_env("MACULA_NODE_ID") do
  config :macula, node_id: node_id
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/swai_node/swai_node.db
      """

  config :swai_node, SwaiNode.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  config :swai_node_web, SwaiNodeWeb.Endpoint,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## Using releases
  #
  # If you are doing OTP releases, you need to instruct Phoenix
  # to start each relevant endpoint:
  #
  #     config :swai_node_web, SwaiNodeWeb.Endpoint, server: true
  #
  # Then you can assemble a release by calling `mix release`.
  # See `mix help release` for more information.

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :swai_node_web, SwaiNodeWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :swai_node_web, SwaiNodeWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :swai_node, SwaiNode.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.

  config :swai_node, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # ============================================================================
  # Production Macula Configuration
  # ============================================================================

  # TLS configuration - use development mode with auto-generated certs for now
  # Production deployments should provide proper certificates
  macula_data_dir = System.get_env("MACULA_DATA_DIR", "/home/app/data/macula")

  config :macula,
    data_dir: macula_data_dir,
    tls_mode: String.to_atom(System.get_env("MACULA_TLS_MODE", "development")),
    tls_cacertfile: System.get_env("MACULA_TLS_CACERTFILE", "/etc/ssl/certs/ca-certificates.crt"),
    tls_certfile: System.get_env("MACULA_TLS_CERTFILE"),
    tls_keyfile: System.get_env("MACULA_TLS_KEYFILE")

  # Production event store configuration
  # Note: erl_esdb stores can be configured via ESDB_STORES environment variable
  # For now, we start without stores and configure them via application code
  # when needed. The swai_events store can be added when event sourcing is enabled.
  esdb_data_dir = System.get_env("ESDB_DATA_DIR", "/home/app/data/esdb")

  # Only configure stores if explicitly enabled
  if System.get_env("ESDB_ENABLED") == "true" do
    config :erl_esdb,
      stores: [
        swai_events: [
          data_dir: esdb_data_dir,
          mode: :single
        ]
      ]
  end
end
