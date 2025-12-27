defmodule SwaiNode.Worlds.World do
  @moduledoc """
  Schema for a simulation world.

  A world is a 2D environment where agents live, evolve, and compete for resources.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SwaiNode.Worlds.Agent

  @type status :: :running | :paused | :stopped

  schema "worlds" do
    field :name, :string
    field :width, :integer, default: 800
    field :height, :integer, default: 600
    field :food_spawn_rate, :float, default: 0.1
    field :max_food, :integer, default: 100
    field :generation, :integer, default: 0
    field :tick, :integer, default: 0
    field :status, Ecto.Enum, values: [:running, :paused, :stopped], default: :stopped

    has_many :agents, Agent

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(world, attrs) do
    world
    |> cast(attrs, [:name, :width, :height, :food_spawn_rate, :max_food, :generation, :tick, :status])
    |> validate_required([:name])
    |> validate_number(:width, greater_than: 0)
    |> validate_number(:height, greater_than: 0)
    |> validate_number(:food_spawn_rate, greater_than_or_equal_to: 0)
    |> validate_number(:max_food, greater_than: 0)
    |> unique_constraint(:name)
  end
end
