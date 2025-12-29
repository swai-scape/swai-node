defmodule SwaiNode.DomainSDK.TestCoevolution do
  @moduledoc """
  Test module for running multi-species coevolution.
  """

  alias SwaiNode.DomainSDK.Species.{ForagerSpecies, PredatorSpecies}
  alias SwaiNode.DomainSDK.MultiSpeciesHexArena

  @doc """
  Run a coevolution test with foragers and predators.

  Usage in IEx:
      SwaiNode.DomainSDK.TestCoevolution.run()
  """
  def run(opts \\ []) do
    max_generations = Keyword.get(opts, :max_generations, 10)
    forager_pop = Keyword.get(opts, :forager_population, 20)
    predator_pop = Keyword.get(opts, :predator_population, 10)

    IO.puts("=== Multi-Species Coevolution Test ===")
    IO.puts("")

    # Show species configurations
    IO.puts("Species Configuration:")
    IO.puts("  Foragers: #{forager_pop} agents")
    show_species_info(ForagerSpecies)
    IO.puts("")
    IO.puts("  Predators: #{predator_pop} agents")
    show_species_info(PredatorSpecies)
    IO.puts("")

    # Create species registry with both species
    IO.puts("Creating species registry...")
    registry_opts = %{
      species: [ForagerSpecies, PredatorSpecies],
      environment: MultiSpeciesHexArena,
      population_sizes: %{
        forager: forager_pop,
        predator: predator_pop
      }
    }

    {:ok, registry} = :species_registry.new(registry_opts)
    IO.puts("Registry created with both species")

    IO.puts("")
    IO.puts("Registry info:")
    species_list = :species_registry.list_species(registry)
    IO.inspect(species_list, label: "  Registered species")
    IO.puts("")

    # Start coevolution trainer
    IO.puts("Starting coevolution trainer...")
    config = %{
      species: [ForagerSpecies, PredatorSpecies],
      environment: MultiSpeciesHexArena,
      population_sizes: %{
        forager: forager_pop,
        predator: predator_pop
      },
      evaluation_mode: :competitive,
      max_generations: max_generations
    }

    case :coevolution_trainer.start(config) do
      {:ok, pid} ->
        IO.puts("Coevolution trainer started: #{inspect(pid)}")
        IO.puts("")
        IO.puts("Running #{max_generations} generations...")

        # Monitor the trainer
        ref = Process.monitor(pid)

        # Wait for completion or timeout
        receive do
          {:DOWN, ^ref, :process, ^pid, :normal} ->
            IO.puts("Training completed normally!")

          {:DOWN, ^ref, :process, ^pid, reason} ->
            IO.puts("Training ended with reason: #{inspect(reason)}")
        after
          60_000 ->
            IO.puts("Training timeout - stopping trainer")
            :coevolution_trainer.stop(pid)
        end

        {:ok, pid}

      {:error, reason} ->
        IO.puts("Failed to start trainer: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp show_species_info(species_module) do
    {inputs, hidden, outputs} = species_module.network_topology()
    IO.puts("    Network: #{inputs} inputs -> #{inspect(hidden)} hidden -> #{outputs} outputs")
    IO.puts("    Sensors: #{length(species_module.sensors())} types")
    IO.puts("    Actuators: #{length(species_module.actuators())} types")
    IO.puts("    Subspeciation threshold: #{species_module.subspeciation_threshold()}")
  end

  @doc """
  Quick test that just creates the registry and bridges without training.
  """
  def test_registry do
    IO.puts("Testing species registry...")

    # Create registry with both species upfront
    registry_opts = %{
      species: [ForagerSpecies, PredatorSpecies],
      environment: MultiSpeciesHexArena,
      population_sizes: %{forager: 20, predator: 10}
    }

    {:ok, registry} = :species_registry.new(registry_opts)
    IO.puts("  Created registry with ForagerSpecies and PredatorSpecies")

    species_list = :species_registry.list_species(registry)
    IO.puts("  Species count: #{length(species_list)}")
    IO.puts("  Species IDs: #{inspect(species_list)}")

    # Test getting bridges
    IO.puts("")
    IO.puts("Testing bridge creation...")
    {:ok, forager_bridge} = :species_registry.get_bridge(registry, :forager)
    IO.puts("  Forager bridge created with topology: #{inspect(Map.get(forager_bridge, :topology))}")
    IO.puts("  Forager inputs: #{Map.get(forager_bridge, :total_inputs)}, outputs: #{Map.get(forager_bridge, :total_outputs)}")

    {:ok, predator_bridge} = :species_registry.get_bridge(registry, :predator)
    IO.puts("  Predator bridge created with topology: #{inspect(Map.get(predator_bridge, :topology))}")
    IO.puts("  Predator inputs: #{Map.get(predator_bridge, :total_inputs)}, outputs: #{Map.get(predator_bridge, :total_outputs)}")

    IO.puts("")
    IO.puts("All tests passed!")

    {:ok, registry}
  end

  @doc """
  Test the environment interaction types.
  """
  def test_interactions do
    IO.puts("Testing interaction types...")

    interactions = [
      {:predator, :forager},
      {:forager, :predator},
      {:predator, :predator},
      {:forager, :forager}
    ]

    for {s1, s2} <- interactions do
      interaction = MultiSpeciesHexArena.interaction_type(s1, s2)
      IO.puts("  #{s1} vs #{s2}: #{interaction}")
    end

    :ok
  end
end
