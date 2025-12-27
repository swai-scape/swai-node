defmodule SwaiNode.Worlds.Agent do
  @moduledoc """
  Schema for an evolved agent in the simulation.

  Agents are neural network-controlled entities that:
  - Move around the world
  - Eat food to gain energy
  - Reproduce when energy is sufficient
  - Die when energy depletes

  The neural network is stored as a binary blob for persistence.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SwaiNode.Worlds.World

  schema "agents" do
    belongs_to :world, World
    belongs_to :parent, __MODULE__

    field :name, :string
    field :x, :float
    field :y, :float
    field :direction, :float, default: 0.0
    field :energy, :float, default: 100.0
    field :age, :integer, default: 0
    field :generation, :integer, default: 0
    field :fitness, :float, default: 0.0
    field :food_eaten, :integer, default: 0
    field :network_binary, :binary
    field :is_alive, :boolean, default: true
    field :species_id, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :world_id,
      :parent_id,
      :name,
      :x,
      :y,
      :direction,
      :energy,
      :age,
      :generation,
      :fitness,
      :food_eaten,
      :network_binary,
      :is_alive,
      :species_id
    ])
    |> validate_required([:world_id, :x, :y])
    |> validate_number(:energy, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:world_id)
    |> foreign_key_constraint(:parent_id)
  end

  @doc """
  Create a changeset for a new agent being born.
  """
  def birth_changeset(agent, attrs) do
    agent
    |> cast(attrs, [:world_id, :parent_id, :name, :x, :y, :direction, :energy, :generation, :network_binary, :species_id])
    |> validate_required([:world_id, :x, :y, :network_binary])
    |> put_change(:is_alive, true)
    |> put_change(:age, 0)
    |> put_change(:fitness, 0.0)
    |> put_change(:food_eaten, 0)
  end

  @doc """
  Create a changeset for updating an agent's state.
  """
  def update_changeset(agent, attrs) do
    agent
    |> cast(attrs, [:x, :y, :direction, :energy, :age, :fitness, :food_eaten, :is_alive])
  end

  @doc """
  Create a changeset for saving a champion agent.
  """
  def champion_changeset(agent, attrs) do
    agent
    |> cast(attrs, [:fitness, :network_binary, :generation, :food_eaten, :age])
  end
end
