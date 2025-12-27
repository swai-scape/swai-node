defmodule SwaiNode.Simulation.LCEventBridge do
  @moduledoc """
  Event bridge between Liquid Conglomerate silos and Phoenix.PubSub.

  Subscribes to silo events via neuroevolution_events (pg-based) and
  broadcasts them to Phoenix.PubSub for LiveView consumption.

  ## Event Flow

      Silo → silo_events → neuroevolution_events → LCEventBridge → Phoenix.PubSub → LiveView

  ## Topics Published

      "lc:silo:updates" - Aggregated silo state updates
      "lc:silo:recommendations" - Recommendation changes from task_silo
      "lc:silo:events" - Event stream for dashboard display
  """

  use GenServer
  require Logger

  @pubsub SwaiNode.PubSub
  @topic "lc:silo:updates"
  @recommendations_topic "lc:silo:recommendations"
  @events_topic "lc:silo:events"
  @max_events 50

  @all_silos [:task, :resource, :temporal, :competitive, :social, :cultural,
              :ecological, :morphological, :developmental, :regulatory,
              :economic, :communication, :distribution]

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get current cached silo states.
  """
  @spec get_state() :: map()
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc """
  Subscribe to silo updates via Phoenix.PubSub.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @doc """
  Subscribe to recommendation updates.
  """
  @spec subscribe_recommendations() :: :ok | {:error, term()}
  def subscribe_recommendations do
    Phoenix.PubSub.subscribe(@pubsub, @recommendations_topic)
  end

  @doc """
  Subscribe to event stream (for dashboard event log).
  """
  @spec subscribe_events() :: :ok | {:error, term()}
  def subscribe_events do
    Phoenix.PubSub.subscribe(@pubsub, @events_topic)
  end

  @doc """
  Get recent events for display.
  """
  @spec get_events() :: list(map())
  def get_events do
    GenServer.call(__MODULE__, :get_events)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Enable all extension silos for full LC visibility
    enable_all_silos()

    # Subscribe to all silo events
    subscribe_to_silos()

    # Initialize state with current silo data
    state = %{
      silos: build_initial_state(),
      events: [],  # Recent events for stream display
      last_update: System.system_time(:millisecond)
    }

    Logger.info("[LCEventBridge] Started, subscribed to #{length(@all_silos)} silos")

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state.silos, state}
  end

  @impl true
  def handle_call(:get_events, _from, state) do
    {:reply, state.events, state}
  end

  # Handle silo signal events
  @impl true
  def handle_info({:silo_signals, silo_name, signals}, state) when is_map(signals) do
    event = build_event(:signals, silo_name, summarize_signals(signals))
    state = state
            |> update_silo_state(silo_name, signals)
            |> track_event(event)
    broadcast_update(state.silos)
    {:noreply, state}
  end

  # Handle single signal event
  @impl true
  def handle_info({:silo_signal, silo_name, signal_name, value}, state) do
    signals = %{signal_name => value}
    event = build_event(:signal, silo_name, "#{signal_name}: #{inspect(value)}")
    state = state
            |> update_silo_state(silo_name, signals)
            |> track_event(event)
    broadcast_update(state.silos)
    {:noreply, state}
  end

  # Handle recommendation events
  @impl true
  def handle_info({:silo_recommendations, silo_name, recommendations}, state) do
    event = build_event(:recommendation, silo_name, summarize_recommendations(recommendations))
    state = state
            |> update_silo_recommendations(silo_name, recommendations)
            |> track_event(event)
    broadcast_recommendations(silo_name, recommendations)
    broadcast_update(state.silos)
    {:noreply, state}
  end

  # Handle lifecycle events
  @impl true
  def handle_info({:silo_lifecycle, silo_name, lifecycle_event}, state) do
    Logger.info("[LCEventBridge] Silo #{silo_name} lifecycle: #{lifecycle_event}")
    event = build_event(:lifecycle, silo_name, to_string(lifecycle_event))
    state = state
            |> update_silo_lifecycle(silo_name, lifecycle_event)
            |> track_event(event)
    broadcast_update(state.silos)
    {:noreply, state}
  end

  # Handle neuro_event format from neuroevolution_events
  @impl true
  def handle_info({:neuro_event, topic, event}, state) when is_binary(topic) and is_map(event) do
    state = handle_neuro_event(topic, event, state)
    {:noreply, state}
  end

  # Handle raw neuroevolution_events format
  @impl true
  def handle_info({topic, event}, state) when is_binary(topic) and is_map(event) do
    state = handle_raw_event(topic, event, state)
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[LCEventBridge] Unknown message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp enable_all_silos do
    alias SwaiNode.Simulation.LCStatus

    try do
      LCStatus.enable_all_extensions()
    catch
      :exit, _ ->
        Logger.warning("[LCEventBridge] Could not enable extension silos - lc_supervisor may not be running")
        :ok
    end
  end

  defp subscribe_to_silos do
    # Subscribe to each silo's events via Erlang silo_events module
    Enum.each(@all_silos, fn silo ->
      try do
        :silo_events.subscribe_to_silo(silo, self())
        :silo_events.subscribe_to_recommendations(silo, self())
      catch
        :exit, _ -> :ok
      end
    end)
  end

  defp build_initial_state do
    enabled = get_enabled_silos()

    Map.new(@all_silos, fn silo ->
      {silo, %{
        type: silo,
        enabled: silo in enabled,
        core: silo in [:task, :resource],
        signals: %{},
        recommendations: %{},
        last_update: nil
      }}
    end)
  end

  defp get_enabled_silos do
    try do
      :lc_supervisor.list_enabled_silos()
    catch
      :exit, _ -> [:task, :resource]
    end
  end

  defp update_silo_state(state, silo_name, signals) do
    silos = Map.update(state.silos, silo_name, %{}, fn silo ->
      %{silo |
        signals: Map.merge(silo[:signals] || %{}, signals),
        last_update: System.system_time(:millisecond)
      }
    end)

    %{state | silos: silos, last_update: System.system_time(:millisecond)}
  end

  defp update_silo_recommendations(state, silo_name, recommendations) do
    silos = Map.update(state.silos, silo_name, %{}, fn silo ->
      %{silo |
        recommendations: recommendations,
        last_update: System.system_time(:millisecond)
      }
    end)

    %{state | silos: silos, last_update: System.system_time(:millisecond)}
  end

  defp update_silo_lifecycle(state, silo_name, event) do
    enabled = case event do
      :activated -> true
      :deactivated -> false
      _ -> get_in(state.silos, [silo_name, :enabled]) || false
    end

    silos = Map.update(state.silos, silo_name, %{}, fn silo ->
      %{silo |
        enabled: enabled,
        last_update: System.system_time(:millisecond)
      }
    end)

    %{state | silos: silos, last_update: System.system_time(:millisecond)}
  end

  # Handle neuro_event format: {:neuro_event, "silo.{name}.signals", %{signal: _, value: _, from: _}}
  defp handle_neuro_event(topic, event, state) do
    # Extract silo name from topic like "silo.temporal.signals"
    case String.split(topic, ".") do
      ["silo", silo_name_str, "signals"] ->
        silo_name = String.to_existing_atom(silo_name_str)
        signal_name = event[:signal] || event["signal"]
        value = event[:value] || event["value"]

        # Build event for stream
        message = "#{signal_name}=#{format_value(value)}"
        stream_event = build_event(:signal, silo_name, message)

        state
        |> update_silo_state(silo_name, %{signal_name => value})
        |> track_event(stream_event)
        |> tap(fn s -> broadcast_update(s.silos) end)

      ["silo", silo_name_str, "recommendations"] ->
        silo_name = String.to_existing_atom(silo_name_str)
        recs = event[:recommendations] || event["recommendations"] || event

        stream_event = build_event(:recommendation, silo_name, summarize_recommendations(recs))

        state
        |> update_silo_recommendations(silo_name, recs)
        |> track_event(stream_event)
        |> tap(fn s ->
          broadcast_recommendations(silo_name, recs)
          broadcast_update(s.silos)
        end)

      _ ->
        state
    end
  rescue
    ArgumentError ->
      # Silo name doesn't exist as atom yet - safe to ignore
      state
  end

  defp handle_raw_event(topic, event, state) do
    case event do
      %{event_type: <<"silo_signals">>, from: silo, signals: signals} ->
        update_silo_state(state, silo, signals)

      %{event_type: <<"silo_signal">>, from: silo, signal: name, value: val} ->
        update_silo_state(state, silo, %{name => val})

      %{event_type: <<"silo_recommendations">>, silo: silo, recommendations: recs} ->
        broadcast_recommendations(silo, recs)
        update_silo_recommendations(state, silo, recs)

      %{event_type: <<"silo_lifecycle">>, silo: silo, lifecycle_event: evt} ->
        update_silo_lifecycle(state, silo, evt)

      _ ->
        Logger.debug("[LCEventBridge] Unhandled event on #{topic}: #{inspect(event)}")
        state
    end
  end

  defp broadcast_update(silos) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:lc_update, silos})
  end

  defp broadcast_recommendations(silo_name, recommendations) do
    Phoenix.PubSub.broadcast(@pubsub, @recommendations_topic,
      {:lc_recommendations, silo_name, recommendations})
  end

  # ===========================================================================
  # Event Stream Helpers
  # ===========================================================================

  defp build_event(type, silo, message) do
    %{
      id: System.unique_integer([:positive]),
      type: type,
      silo: silo,
      message: message,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp track_event(state, event) do
    events = [event | state.events] |> Enum.take(@max_events)
    broadcast_event(event)
    %{state | events: events}
  end

  defp broadcast_event(event) do
    Phoenix.PubSub.broadcast(@pubsub, @events_topic, {:lc_event, event})
  end

  defp summarize_signals(signals) when is_map(signals) do
    signals
    |> Enum.take(3)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{format_value(v)}" end)
  end

  defp summarize_recommendations(recs) when is_map(recs) do
    recs
    |> Enum.take(2)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{format_value(v)}" end)
  end

  defp format_value(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 3)
  defp format_value(v), do: inspect(v)
end
