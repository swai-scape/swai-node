defmodule SwaiNodeWeb.HealthController do
  @moduledoc """
  Health check endpoint for container orchestration and load balancers.

  Returns 200 OK when the application is healthy, with detailed status in JSON body.
  Returns 503 Service Unavailable when the application is unhealthy.
  """

  use SwaiNodeWeb, :controller

  @doc """
  Basic health check - returns 200 if the application is running.
  """
  def check(conn, _params) do
    health = get_health_status()

    status_code =
      case health.status do
        :healthy -> 200
        :degraded -> 200
        :unhealthy -> 503
      end

    conn
    |> put_status(status_code)
    |> json(health)
  end

  @doc """
  Detailed health check with component status.
  """
  def detailed(conn, _params) do
    health = get_detailed_health()

    status_code =
      case health.status do
        :healthy -> 200
        :degraded -> 200
        :unhealthy -> 503
      end

    conn
    |> put_status(status_code)
    |> json(health)
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  defp get_health_status do
    mesh_connected = mesh_healthy?()
    db_connected = database_healthy?()

    status =
      cond do
        mesh_connected and db_connected -> :healthy
        db_connected -> :degraded
        true -> :unhealthy
      end

    %{
      status: status,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      version: Application.spec(:swai_node, :vsn) |> to_string()
    }
  end

  defp get_detailed_health do
    mesh_status = mesh_status()
    db_status = database_status()

    components = %{
      mesh: mesh_status,
      database: db_status
    }

    overall_status =
      cond do
        mesh_status.healthy and db_status.healthy -> :healthy
        db_status.healthy -> :degraded
        true -> :unhealthy
      end

    %{
      status: overall_status,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      version: Application.spec(:swai_node, :vsn) |> to_string(),
      components: components,
      node: node_info()
    }
  end

  defp mesh_healthy? do
    try do
      SwaiNode.MeshClient.connected?()
    rescue
      _ -> false
    catch
      :exit, _ -> false
    end
  end

  defp mesh_status do
    try do
      status = SwaiNode.MeshClient.status()

      %{
        healthy: status.connected,
        node_id: status.node_id,
        realm: status.realm,
        bootstrap_nodes: status.bootstrap_nodes
      }
    rescue
      _ -> %{healthy: false, error: "mesh_client_unavailable"}
    catch
      :exit, _ -> %{healthy: false, error: "mesh_client_unavailable"}
    end
  end

  defp database_healthy? do
    try do
      SwaiNode.Repo.query!("SELECT 1")
      true
    rescue
      _ -> false
    end
  end

  defp database_status do
    try do
      SwaiNode.Repo.query!("SELECT 1")
      %{healthy: true, adapter: "ecto_sqlite3"}
    rescue
      e -> %{healthy: false, error: Exception.message(e)}
    end
  end

  defp node_info do
    %{
      hostname: node_hostname(),
      uptime_seconds: node_uptime(),
      memory_mb: memory_usage_mb()
    }
  end

  defp node_hostname do
    {:ok, hostname} = :inet.gethostname()
    to_string(hostname)
  end

  defp node_uptime do
    {uptime, _} = :erlang.statistics(:wall_clock)
    div(uptime, 1000)
  end

  defp memory_usage_mb do
    memory = :erlang.memory(:total)
    Float.round(memory / 1_048_576, 2)
  end
end
