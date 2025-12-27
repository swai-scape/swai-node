defmodule SwaiNode.MeshClient do
  @moduledoc """
  Macula mesh client for SwaiNode.

  Provides connection to the macula HTTP/3 mesh network for:
  - P2P communication with other swai-nodes
  - Service discovery via DHT
  - Pub/Sub for real-time battle events
  - RPC for warrior battles and trading
  """

  use GenServer
  require Logger

  @type state :: %{
          peer_pid: pid() | nil,
          node_id: binary(),
          realm: binary(),
          connected: boolean(),
          standalone_mode: boolean()
        }

  # =============================================================================
  # Client API
  # =============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if connected to the mesh.
  """
  @spec connected?() :: boolean()
  def connected? do
    GenServer.call(__MODULE__, :connected?)
  end

  @doc """
  Get the local node ID.
  """
  @spec node_id() :: binary() | nil
  def node_id do
    GenServer.call(__MODULE__, :node_id)
  end

  @doc """
  Publish a message to a topic.
  """
  @spec publish(binary(), term()) :: :ok | {:error, term()}
  def publish(topic, message) do
    GenServer.call(__MODULE__, {:publish, topic, message})
  end

  @doc """
  Subscribe to a topic with a callback function.
  """
  @spec subscribe(binary(), (term() -> any())) :: :ok | {:error, term()}
  def subscribe(topic, callback) when is_function(callback, 1) do
    GenServer.call(__MODULE__, {:subscribe, topic, callback})
  end

  @doc """
  Make an RPC call to a remote procedure.
  """
  @spec call(binary(), term()) :: {:ok, term()} | {:error, term()}
  def call(procedure, args) do
    GenServer.call(__MODULE__, {:rpc_call, procedure, args}, 30_000)
  end

  @doc """
  Register a local procedure handler.
  """
  @spec register_procedure(binary(), (term() -> {:ok, term()} | {:error, term()})) ::
          :ok | {:error, term()}
  def register_procedure(procedure, handler) when is_function(handler, 1) do
    GenServer.call(__MODULE__, {:register_procedure, procedure, handler})
  end

  @doc """
  Get mesh connection status and stats.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Check if running in standalone mode (no mesh connectivity).
  """
  @spec standalone?() :: boolean()
  def standalone? do
    GenServer.call(__MODULE__, :standalone?)
  end

  # =============================================================================
  # Server Callbacks
  # =============================================================================

  @impl true
  def init(opts) do
    bootstrap_nodes = opts[:bootstrap_nodes] || get_bootstrap_nodes()

    state = %{
      peer_pid: nil,
      node_id: opts[:node_id] || generate_node_id(),
      realm: opts[:realm] || get_realm(),
      connected: false,
      standalone_mode: bootstrap_nodes == [],
      bootstrap_nodes: bootstrap_nodes,
      subscriptions: %{},
      procedures: %{}
    }

    # Only attempt connection if we have bootstrap nodes
    if bootstrap_nodes != [] do
      send(self(), :connect)
    else
      Logger.info("[MeshClient] Running in standalone mode (no bootstrap nodes configured)")
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  @impl true
  def handle_call(:standalone?, _from, state) do
    {:reply, state.standalone_mode, state}
  end

  @impl true
  def handle_call(:node_id, _from, state) do
    {:reply, state.node_id, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      connected: state.connected,
      standalone_mode: state.standalone_mode,
      node_id: state.node_id,
      realm: state.realm,
      bootstrap_nodes: state.bootstrap_nodes,
      subscriptions: Map.keys(state.subscriptions),
      procedures: Map.keys(state.procedures)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call({:publish, _topic, _message}, _from, %{connected: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  @impl true
  def handle_call({:publish, topic, message}, _from, %{peer_pid: peer_pid} = state) do
    result = :macula_peer.publish(peer_pid, topic, message)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:subscribe, topic, callback}, _from, %{connected: false} = state) do
    # Store subscription to apply when connected
    new_subs = Map.put(state.subscriptions, topic, callback)
    {:reply, {:ok, :pending}, %{state | subscriptions: new_subs}}
  end

  @impl true
  def handle_call({:subscribe, topic, callback}, _from, %{peer_pid: peer_pid} = state) do
    # Wrap callback to handle messages
    wrapper = fn msg ->
      callback.(msg)
    end

    case :macula_peer.subscribe(peer_pid, topic, wrapper) do
      :ok ->
        new_subs = Map.put(state.subscriptions, topic, callback)
        {:reply, :ok, %{state | subscriptions: new_subs}}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:rpc_call, _procedure, _args}, _from, %{connected: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  @impl true
  def handle_call({:rpc_call, procedure, args}, from, %{peer_pid: peer_pid} = state) do
    # Use async RPC with callback
    callback = fn result ->
      GenServer.reply(from, result)
    end

    case :macula_peer.call(peer_pid, procedure, args, %{callback: callback}) do
      {:ok, _request_id} ->
        {:noreply, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:register_procedure, procedure, handler}, _from, state) do
    new_procs = Map.put(state.procedures, procedure, handler)
    new_state = %{state | procedures: new_procs}

    # Note: Procedure registration with the mesh happens via DHT advertisement
    # when the connection is established. For now, we store locally.
    # TODO: Integrate with macula_rpc_handler for proper service registration

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:connect, %{standalone_mode: true} = state) do
    # In standalone mode, don't attempt to connect
    {:noreply, state}
  end

  @impl true
  def handle_info(:connect, state) do
    case connect_to_mesh(state) do
      {:ok, peer_pid} ->
        Logger.info("[MeshClient] Connected to macula mesh as #{state.node_id}")

        # Apply pending subscriptions
        Enum.each(state.subscriptions, fn {topic, callback} ->
          :macula_peer.subscribe(peer_pid, topic, callback)
        end)

        # Note: Procedure registration would happen here when macula supports it
        # For now, procedures are stored locally for future mesh integration
        _ = state.procedures

        {:noreply, %{state | peer_pid: peer_pid, connected: true, standalone_mode: false}}

      {:error, :no_bootstrap_nodes} ->
        # Switch to standalone mode, don't retry
        Logger.info("[MeshClient] No bootstrap nodes configured, switching to standalone mode")
        {:noreply, %{state | standalone_mode: true}}

      {:error, reason} ->
        Logger.warning("[MeshClient] Failed to connect to mesh: #{inspect(reason)}, retrying in 30s")
        Process.send_after(self(), :connect, 30_000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{peer_pid: pid} = state) do
    Logger.warning("Mesh connection lost: #{inspect(reason)}, reconnecting...")
    Process.send_after(self(), :connect, 1_000)
    {:noreply, %{state | peer_pid: nil, connected: false}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  defp connect_to_mesh(state) do
    bootstrap_nodes = state.bootstrap_nodes

    case bootstrap_nodes do
      [] ->
        {:error, :no_bootstrap_nodes}

      [node | _rest] ->
        url = "quic://#{node}"

        opts = %{
          node_id: state.node_id,
          realm: state.realm
        }

        case :macula_peer.start_link(url, opts) do
          {:ok, pid} ->
            Process.monitor(pid)
            {:ok, pid}

          error ->
            error
        end
    end
  end

  defp generate_node_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end

  defp get_realm do
    Application.get_env(:macula, :realm, "swai.dev")
  end

  defp get_bootstrap_nodes do
    Application.get_env(:macula, :bootstrap_nodes, [])
  end
end
