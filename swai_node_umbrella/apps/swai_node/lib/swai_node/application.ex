defmodule SwaiNode.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Register domain bridge with signal_router for silo communication
    :signal_router.register_domain_module(SwaiNode.Domain.DomainBridge)

    children = [
      SwaiNode.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:swai_node, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:swai_node, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: SwaiNode.PubSub},
      # Macula mesh client for P2P communication
      SwaiNode.MeshClient,
      # LC event bridge (silo events → Phoenix.PubSub)
      SwaiNode.Simulation.LCEventBridge,
      # Training server (neuroevolution coordinator)
      SwaiNode.Training.TrainingServer,
      # Projections (subscribe to training events, build read models)
      SwaiNode.Projections.FitnessHistory,
      SwaiNode.Projections.ChampionArchive,
      # Hex arena simulation server (for visualization)
      SwaiNode.Simulation.HexWorldServer
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SwaiNode.Supervisor)
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
