# Swai Node - Production Dockerfile with NIF Support
#
# Multi-stage build for Elixir Phoenix application with Rust NIFs.
# Uses hex.pm for macula, macula-tweann, macula-neuroevolution, erl-esdb, erl-evoq.
# Uses git dependencies (with GitHub token) for macula-nn-nifs and erl-esdb-nifs.
#
# Build arguments:
#   BUILD_DATE - Build timestamp
#   VCS_REF - Git commit SHA
#   CACHE_BUST - Cache buster for forced rebuilds
#
# Requires:
#   GITHUB_TOKEN - Build secret for private git repos
#
# Build command:
#   DOCKER_BUILDKIT=1 docker build \
#     --secret id=github_token,env=GITHUB_TOKEN \
#     --build-arg CACHE_BUST=$(date +%s) \
#     -t swai-node:latest \
#     -f docker/Dockerfile .

ARG ELIXIR_VERSION=1.17.2
ARG OTP_VERSION=27.0
ARG DEBIAN_VERSION=bookworm-20240701-slim
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# =============================================================================
# Build Stage
# =============================================================================
FROM ${BUILDER_IMAGE} AS builder

ARG BUILD_DATE
ARG VCS_REF
ARG CACHE_BUST

LABEL org.opencontainers.image.created="${BUILD_DATE}"
LABEL org.opencontainers.image.revision="${VCS_REF}"

# Install build dependencies including Rust toolchain, Node.js, and cmake (for quicer/MsQUIC)
RUN apt-get update -y && apt-get install -y \
    build-essential \
    git \
    curl \
    nodejs \
    npm \
    cmake \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Rust (required for NIF compilation - macula-nn-nifs, erl-esdb-nifs)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# Verify Rust installation
RUN rustc --version && cargo --version

# Set environment for production build
ENV MIX_ENV=prod
ENV ERL_FLAGS="+JPperf true"

WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy the umbrella project
COPY swai_node_umbrella/mix.exs swai_node_umbrella/mix.lock ./
COPY swai_node_umbrella/config config
COPY swai_node_umbrella/apps apps
COPY swai_node_umbrella/rel rel

# Get dependencies using GitHub token for private git repos
# The token is mounted as a secret and used to configure git credentials
RUN --mount=type=secret,id=github_token \
    if [ -f /run/secrets/github_token ]; then \
        GITHUB_TOKEN=$(cat /run/secrets/github_token) && \
        git config --global url."https://${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/" && \
        echo "Git configured with GitHub token for private repos"; \
    else \
        echo "Warning: No GitHub token provided, private git deps will fail"; \
    fi && \
    mix deps.get --only $MIX_ENV

# Compile dependencies (including Rust NIFs)
# Note: erl_esdb_gater must be compiled before erl_evoq due to header dependency
RUN mix deps.compile erl_esdb_gater && mix deps.compile

# Verify NIF compilation succeeded
RUN test -f deps/macula_nn_nifs/priv/libmacula_nn_nifs.so && \
    echo "macula-nn-nifs NIF compiled: $(ls -la deps/macula_nn_nifs/priv/)" || \
    echo "Warning: macula-nn-nifs NIF not found, will use pure Erlang fallback"

# Note: erl_esdb_nifs disabled for now - needs proper Rust NIF compilation setup

# Install tailwind and esbuild binaries
RUN mix tailwind.install --if-missing
RUN mix esbuild.install --if-missing

# Build assets (tailwind + esbuild)
RUN mix assets.deploy

# Compile application
RUN mix compile

# Build release
RUN mix release swai_node

# =============================================================================
# Runner Stage
# =============================================================================
FROM ${RUNNER_IMAGE} AS runner

ARG BUILD_DATE
ARG VCS_REF

LABEL org.opencontainers.image.created="${BUILD_DATE}"
LABEL org.opencontainers.image.revision="${VCS_REF}"
LABEL org.opencontainers.image.title="SwaiNode"
LABEL org.opencontainers.image.description="Swarm Wars AI Node - Decentralized Competitive Evolution"
LABEL org.opencontainers.image.vendor="swai-scape"

# Install runtime dependencies
RUN apt-get update -y && apt-get install -y \
    libstdc++6 \
    openssl \
    libncurses5 \
    locales \
    curl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Set locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Create app user
RUN useradd --create-home --shell /bin/bash app

# Create macula system directory (macula has hardcoded /var/lib/macula for TLS certs)
RUN mkdir -p /var/lib/macula && chown app:app /var/lib/macula

USER app
WORKDIR /home/app

# Copy release from builder
COPY --from=builder --chown=app:app /app/_build/prod/rel/swai_node ./

# Create data directories (both for volume mount and app-local)
RUN mkdir -p /home/app/data/esdb /home/app/data/sqlite /home/app/data/macula

# Create /data directory for docker volume mount (as app user can't create it)
USER root
RUN mkdir -p /data/esdb /data/sqlite /data/macula && chown -R app:app /data
USER app

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:4000/health || exit 1

# Expose ports
# 4000 - Phoenix web server
# 9443 - QUIC/H3 mesh port (optional, for gateway mode)
EXPOSE 4000 9443

# Environment variables with defaults
ENV PORT=4000
ENV DATABASE_PATH=/home/app/data/sqlite/swai_node.db
ENV ESDB_DATA_DIR=/home/app/data/esdb
ENV MACULA_TLS_MODE=development

# Start command (runs migrations then starts server)
CMD ["bin/start"]
