defmodule SwaiNode.Worlds do
  @moduledoc """
  Context module for managing worlds and agents.

  Provides database operations for:
  - Creating and managing worlds
  - Persisting champion agents
  - Loading agents for simulation
  """

  import Ecto.Query
  alias SwaiNode.Repo
  alias SwaiNode.Worlds.{World, Agent}

  # =============================================================================
  # World Operations
  # =============================================================================

  @doc """
  Get or create the default world.
  """
  def get_or_create_default_world do
    case Repo.get_by(World, name: "default") do
      nil -> create_world(%{name: "default"})
      world -> {:ok, world}
    end
  end

  @doc """
  Create a new world.
  """
  def create_world(attrs) do
    %World{}
    |> World.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get a world by ID.
  """
  def get_world(id), do: Repo.get(World, id)

  @doc """
  Update a world's status.
  """
  def update_world_status(world, status) do
    world
    |> World.changeset(%{status: status})
    |> Repo.update()
  end

  @doc """
  Increment the world's generation counter.
  """
  def increment_generation(world) do
    world
    |> World.changeset(%{generation: world.generation + 1})
    |> Repo.update()
  end

  @doc """
  Update world tick count.
  """
  def update_tick(world, tick) do
    world
    |> World.changeset(%{tick: tick})
    |> Repo.update()
  end

  # =============================================================================
  # Agent Operations
  # =============================================================================

  @doc """
  Create a new agent (birth).
  """
  def create_agent(attrs) do
    %Agent{}
    |> Agent.birth_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get an agent by ID.
  """
  def get_agent(id), do: Repo.get(Agent, id)

  @doc """
  Mark an agent as dead.
  """
  def kill_agent(agent) do
    agent
    |> Agent.update_changeset(%{is_alive: false, energy: 0.0})
    |> Repo.update()
  end

  @doc """
  Update agent state (for champion persistence).
  """
  def update_agent(agent, attrs) do
    agent
    |> Agent.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Save a champion agent's network.
  """
  def save_champion(agent, attrs) do
    agent
    |> Agent.champion_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Get top N agents by fitness for a world.
  """
  def get_top_agents(world_id, limit \\ 10) do
    Agent
    |> where([a], a.world_id == ^world_id and a.is_alive == true)
    |> order_by([a], desc: a.fitness)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Get all living agents for a world.
  """
  def get_living_agents(world_id) do
    Agent
    |> where([a], a.world_id == ^world_id and a.is_alive == true)
    |> Repo.all()
  end

  @doc """
  Count living agents in a world.
  """
  def count_living_agents(world_id) do
    Agent
    |> where([a], a.world_id == ^world_id and a.is_alive == true)
    |> Repo.aggregate(:count)
  end

  @doc """
  Get aggregate stats for a world.
  """
  def get_world_stats(world_id) do
    query =
      from a in Agent,
        where: a.world_id == ^world_id and a.is_alive == true,
        select: %{
          count: count(a.id),
          avg_fitness: avg(a.fitness),
          max_fitness: max(a.fitness),
          avg_energy: avg(a.energy),
          avg_age: avg(a.age),
          total_food_eaten: sum(a.food_eaten)
        }

    case Repo.one(query) do
      nil -> %{count: 0, avg_fitness: 0.0, max_fitness: 0.0, avg_energy: 0.0, avg_age: 0, total_food_eaten: 0}
      stats -> stats
    end
  end

  @doc """
  Delete all agents in a world (for reset).
  """
  def delete_all_agents(world_id) do
    Agent
    |> where([a], a.world_id == ^world_id)
    |> Repo.delete_all()
  end

  @doc """
  Load champions from database (for seeding new simulation).
  """
  def load_champions(world_id, limit \\ 10) do
    Agent
    |> where([a], a.world_id == ^world_id)
    |> where([a], not is_nil(a.network_binary))
    |> order_by([a], desc: a.fitness)
    |> limit(^limit)
    |> Repo.all()
  end
end
