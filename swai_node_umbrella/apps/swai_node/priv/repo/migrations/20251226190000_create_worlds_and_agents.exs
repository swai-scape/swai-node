defmodule SwaiNode.Repo.Migrations.CreateWorldsAndAgents do
  use Ecto.Migration

  def change do
    create table(:worlds) do
      add :name, :string, null: false
      add :width, :integer, default: 800
      add :height, :integer, default: 600
      add :food_spawn_rate, :float, default: 0.1
      add :max_food, :integer, default: 100
      add :generation, :integer, default: 0
      add :tick, :integer, default: 0
      add :status, :string, default: "stopped"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:worlds, [:name])

    create table(:agents) do
      add :world_id, references(:worlds, on_delete: :delete_all), null: false
      add :name, :string
      add :x, :float
      add :y, :float
      add :direction, :float, default: 0.0
      add :energy, :float, default: 100.0
      add :age, :integer, default: 0
      add :generation, :integer, default: 0
      add :fitness, :float, default: 0.0
      add :food_eaten, :integer, default: 0
      add :network_binary, :binary
      add :is_alive, :boolean, default: true
      add :species_id, :string
      add :parent_id, references(:agents, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:agents, [:world_id])
    create index(:agents, [:is_alive])
    create index(:agents, [:fitness])
    create index(:agents, [:species_id])
  end
end
