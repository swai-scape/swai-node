defmodule SwaiNode.DomainSDK.TestCoevolution do
  @moduledoc """
  Test module for running multi-species coevolution with fitness tracking and visualization.
  """

  alias SwaiNode.DomainSDK.Species.{ForagerSpecies, PredatorSpecies}
  alias SwaiNode.DomainSDK.MultiSpeciesHexArena

  @doc """
  Run coevolution with species-specific fitness tracking and charts.

  Usage:
      SwaiNode.DomainSDK.TestCoevolution.run_with_charts(generations: 15)
  """
  def run_with_charts(opts \\ []) do
    max_generations = Keyword.get(opts, :generations, 15)
    forager_pop = Keyword.get(opts, :forager_population, 10)
    predator_pop = Keyword.get(opts, :predator_population, 5)
    episodes = Keyword.get(opts, :episodes_per_eval, 3)

    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("  MULTI-SPECIES COEVOLUTION WITH FITNESS TRACKING")
    IO.puts(String.duplicate("=", 60))
    IO.puts("")
    IO.puts("Configuration:")
    IO.puts("  Generations: #{max_generations}")
    IO.puts("  Foragers: #{forager_pop} agents")
    IO.puts("  Predators: #{predator_pop} agents")
    IO.puts("  Episodes per evaluation: #{episodes}")
    IO.puts("")

    # Create registry
    registry_opts = %{
      species: [ForagerSpecies, PredatorSpecies],
      environment: MultiSpeciesHexArena,
      population_sizes: %{forager: forager_pop, predator: predator_pop}
    }
    {:ok, registry} = :species_registry.new(registry_opts)

    # Initialize fitness history
    history = %{
      forager: %{best: [], avg: [], min: []},
      predator: %{best: [], avg: [], min: []}
    }

    IO.puts("Running #{max_generations} generations...\n")

    # Run generations manually to capture fitness
    {final_registry, final_history} = run_generations(registry, max_generations, episodes, history)

    # Display results
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("  RESULTS")
    IO.puts(String.duplicate("=", 60))

    display_fitness_table(final_history, max_generations)
    IO.puts("")

    # Generate ASCII charts
    generate_ascii_chart("FORAGER FITNESS", final_history.forager, max_generations)
    generate_ascii_chart("PREDATOR FITNESS", final_history.predator, max_generations)

    # Generate SVG chart
    svg_path = "/tmp/coevolution_fitness.svg"
    generate_svg_chart(final_history, max_generations, svg_path)
    IO.puts("\nSVG chart saved to: #{svg_path}")

    {:ok, final_registry, final_history}
  end

  defp run_generations(registry, max_gen, episodes, history) do
    Enum.reduce(1..max_gen, {registry, history}, fn gen, {reg, hist} ->
      IO.write("\rGeneration #{gen}/#{max_gen}...")

      # Evaluate both species
      {forager_fitness, reg} = evaluate_species(reg, :forager, ForagerSpecies, episodes)
      {predator_fitness, reg} = evaluate_species(reg, :predator, PredatorSpecies, episodes)

      # Update history
      new_hist = %{
        forager: update_history(hist.forager, forager_fitness),
        predator: update_history(hist.predator, predator_fitness)
      }

      # Print generation summary
      IO.puts("\rGen #{String.pad_leading("#{gen}", 3)}: " <>
        "Forager [best: #{format_num(hd(new_hist.forager.best))}, avg: #{format_num(hd(new_hist.forager.avg))}] | " <>
        "Predator [best: #{format_num(hd(new_hist.predator.best))}, avg: #{format_num(hd(new_hist.predator.avg))}]")

      # Evolve populations (selection + mutation)
      reg = evolve_species(reg, :forager, forager_fitness)
      reg = evolve_species(reg, :predator, predator_fitness)

      {reg, new_hist}
    end)
  end

  defp evaluate_species(registry, species_id, species_module, episodes) do
    {:ok, bridge} = :species_registry.get_bridge(registry, species_id)
    population = :species_registry.get_population(registry, species_id)

    # If no population, initialize one
    population = if population == [] do
      pop_size = :species_registry.get_population_size(registry, species_id)
      create_initial_population(species_module, pop_size)
    else
      population
    end

    # Evaluate each network
    fitness_list = Enum.map(population, fn network ->
      fitness = evaluate_network(bridge, network, species_id, episodes)
      {network, fitness}
    end)

    # Sort by fitness descending
    sorted = Enum.sort_by(fitness_list, fn {_, f} -> f end, :desc)

    # Update registry with population
    networks = Enum.map(sorted, fn {n, _} -> n end)
    registry = :species_registry.set_population(registry, species_id, networks)

    {sorted, registry}
  end

  defp evaluate_network(bridge, network, species_id, episodes) do
    fitnesses = for _ <- 1..episodes do
      case :agent_bridge.run_episode(bridge, network, %{}, species_id) do
        {:ok, fitness, _metrics} -> fitness
        {:ok, _metrics} -> 0.0
        {:error, _} -> 0.0
      end
    end
    Enum.sum(fitnesses) / length(fitnesses)
  end

  defp create_initial_population(species_module, size) do
    {inputs, hidden, outputs} = species_module.network_topology()
    for _ <- 1..size do
      create_random_network(inputs, hidden, outputs)
    end
  end

  defp create_random_network(inputs, hidden_layers, outputs) do
    # Create Erlang network using network_evaluator
    # hidden_layers is a list like [8, 8] -> pass as Erlang list
    :network_evaluator.create_feedforward(inputs, hidden_layers, outputs, :tanh)
  end

  defp evolve_species(registry, species_id, fitness_list) do
    # Simple evolution: keep top 30%, mutate and crossover to fill rest
    pop_size = length(fitness_list)
    keep_count = max(2, round(pop_size * 0.3))

    survivors = fitness_list
    |> Enum.take(keep_count)
    |> Enum.map(fn {net, _} -> net end)

    num_survivors = length(survivors)

    # Fill rest with crossover + mutation
    offspring = for _ <- 1..(pop_size - keep_count) do
      case num_survivors do
        1 ->
          # Only one survivor - just mutate
          parent = hd(survivors)
          mutate_network(parent)
        _ ->
          # Two or more - do crossover then mutate (70% chance)
          if :rand.uniform() < 0.7 do
            parent1 = Enum.random(survivors)
            parent2 = Enum.random(survivors -- [parent1]) || parent1
            child = :network_factory.crossover(parent1, parent2)
            mutate_network(child)
          else
            parent = Enum.random(survivors)
            mutate_network(parent)
          end
      end
    end

    new_pop = survivors ++ offspring
    :species_registry.set_population(registry, species_id, new_pop)
  end

  defp mutate_network(network) do
    # Use Erlang network_factory mutation with gaussian noise
    # Mutation strength of 0.3 provides moderate variation
    :network_factory.mutate(network, 0.3)
  end

  defp update_history(hist, fitness_list) do
    fitnesses = Enum.map(fitness_list, fn {_, f} -> f end)
    best = Enum.max(fitnesses, fn -> 0.0 end)
    avg = if length(fitnesses) > 0, do: Enum.sum(fitnesses) / length(fitnesses), else: 0.0
    min = Enum.min(fitnesses, fn -> 0.0 end)

    %{
      best: [best | hist.best],
      avg: [avg | hist.avg],
      min: [min | hist.min]
    }
  end

  defp display_fitness_table(history, generations) do
    IO.puts("\nFitness Summary Table:")
    IO.puts(String.duplicate("-", 70))
    IO.puts("Gen  | Forager Best | Forager Avg | Predator Best | Predator Avg")
    IO.puts(String.duplicate("-", 70))

    forager_best = Enum.reverse(history.forager.best)
    forager_avg = Enum.reverse(history.forager.avg)
    predator_best = Enum.reverse(history.predator.best)
    predator_avg = Enum.reverse(history.predator.avg)

    for i <- 0..(generations - 1) do
      fb = Enum.at(forager_best, i, 0)
      fa = Enum.at(forager_avg, i, 0)
      pb = Enum.at(predator_best, i, 0)
      pa = Enum.at(predator_avg, i, 0)
      IO.puts("#{String.pad_leading("#{i+1}", 4)} | #{String.pad_leading(format_num(fb), 12)} | #{String.pad_leading(format_num(fa), 11)} | #{String.pad_leading(format_num(pb), 13)} | #{String.pad_leading(format_num(pa), 12)}")
    end
    IO.puts(String.duplicate("-", 70))
  end

  defp generate_ascii_chart(title, species_hist, generations) do
    best = Enum.reverse(species_hist.best)
    avg = Enum.reverse(species_hist.avg)

    all_values = best ++ avg
    max_val = Enum.max(all_values, fn -> 1.0 end)
    min_val = Enum.min(all_values, fn -> 0.0 end)
    range = max(max_val - min_val, 1.0)

    height = 12
    width = min(generations, 50)

    IO.puts("\n#{title}")
    IO.puts(String.duplicate("-", width + 10))

    # Draw chart rows (top to bottom)
    for row <- height..0 do
      threshold = min_val + (row / height) * range
      label = if rem(row, 3) == 0, do: String.pad_leading(format_num(threshold), 6), else: "      "

      line = for col <- 0..(width - 1) do
        best_val = Enum.at(best, col, 0)
        avg_val = Enum.at(avg, col, 0)

        cond do
          best_val >= threshold and avg_val >= threshold -> "█"
          best_val >= threshold -> "▀"
          avg_val >= threshold -> "▄"
          true -> " "
        end
      end

      IO.puts("#{label} |#{Enum.join(line)}")
    end

    # X-axis
    IO.puts("       +" <> String.duplicate("-", width))
    IO.puts("        1" <> String.duplicate(" ", max(0, width - 6)) <> "#{generations}")
    IO.puts("        [█ = Best, ▄ = Average]")
  end

  defp generate_svg_chart(history, generations, path) do
    width = 800
    height = 400
    padding = 60

    forager_best = Enum.reverse(history.forager.best)
    forager_avg = Enum.reverse(history.forager.avg)
    predator_best = Enum.reverse(history.predator.best)
    predator_avg = Enum.reverse(history.predator.avg)

    all_values = forager_best ++ forager_avg ++ predator_best ++ predator_avg
    max_val = Enum.max(all_values, fn -> 100.0 end)
    min_val = max(0, Enum.min(all_values, fn -> 0.0 end) - 10)

    # Scale functions
    x_scale = fn i -> padding + (i / max(generations - 1, 1)) * (width - 2 * padding) end
    y_scale = fn v -> height - padding - ((v - min_val) / max(max_val - min_val, 1)) * (height - 2 * padding) end

    # Generate path data
    forager_best_path = generate_path_data(forager_best, x_scale, y_scale)
    forager_avg_path = generate_path_data(forager_avg, x_scale, y_scale)
    predator_best_path = generate_path_data(predator_best, x_scale, y_scale)
    predator_avg_path = generate_path_data(predator_avg, x_scale, y_scale)

    svg = """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{width} #{height}">
      <style>
        .title { font: bold 16px sans-serif; }
        .axis-label { font: 12px sans-serif; }
        .legend { font: 11px sans-serif; }
        .grid { stroke: #e0e0e0; stroke-width: 1; }
      </style>

      <!-- Background -->
      <rect width="#{width}" height="#{height}" fill="#fafafa"/>

      <!-- Title -->
      <text x="#{width/2}" y="25" text-anchor="middle" class="title">Multi-Species Coevolution Fitness</text>

      <!-- Grid lines -->
      #{generate_grid_lines(width, height, padding, min_val, max_val, generations)}

      <!-- Axes -->
      <line x1="#{padding}" y1="#{height - padding}" x2="#{width - padding}" y2="#{height - padding}" stroke="black" stroke-width="2"/>
      <line x1="#{padding}" y1="#{padding}" x2="#{padding}" y2="#{height - padding}" stroke="black" stroke-width="2"/>

      <!-- Axis labels -->
      <text x="#{width/2}" y="#{height - 10}" text-anchor="middle" class="axis-label">Generation</text>
      <text x="15" y="#{height/2}" text-anchor="middle" transform="rotate(-90, 15, #{height/2})" class="axis-label">Fitness</text>

      <!-- Data lines -->
      <path d="#{forager_best_path}" fill="none" stroke="#22c55e" stroke-width="3" stroke-linecap="round"/>
      <path d="#{forager_avg_path}" fill="none" stroke="#22c55e" stroke-width="2" stroke-dasharray="5,3" opacity="0.7"/>
      <path d="#{predator_best_path}" fill="none" stroke="#ef4444" stroke-width="3" stroke-linecap="round"/>
      <path d="#{predator_avg_path}" fill="none" stroke="#ef4444" stroke-width="2" stroke-dasharray="5,3" opacity="0.7"/>

      <!-- Legend -->
      <rect x="#{width - 180}" y="40" width="170" height="80" fill="white" stroke="#ccc" rx="5"/>
      <line x1="#{width - 170}" y1="60" x2="#{width - 140}" y2="60" stroke="#22c55e" stroke-width="3"/>
      <text x="#{width - 135}" y="64" class="legend">Forager Best</text>
      <line x1="#{width - 170}" y1="80" x2="#{width - 140}" y2="80" stroke="#22c55e" stroke-width="2" stroke-dasharray="5,3"/>
      <text x="#{width - 135}" y="84" class="legend">Forager Avg</text>
      <line x1="#{width - 170}" y1="100" x2="#{width - 140}" y2="100" stroke="#ef4444" stroke-width="3"/>
      <text x="#{width - 135}" y="104" class="legend">Predator Best</text>
      <line x1="#{width - 170}" y1="120" x2="#{width - 140}" y2="120" stroke="#ef4444" stroke-width="2" stroke-dasharray="5,3"/>
      <text x="#{width - 135}" y="124" class="legend">Predator Avg</text>
    </svg>
    """

    File.write!(path, svg)
  end

  defp generate_path_data(values, x_scale, y_scale) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {v, i} -> "#{if i == 0, do: "M", else: "L"}#{round(x_scale.(i))},#{round(y_scale.(v))}" end)
    |> Enum.join(" ")
  end

  defp generate_grid_lines(width, height, padding, min_val, max_val, generations) do
    # Horizontal grid lines
    h_lines = for i <- 0..4 do
      y = padding + (i / 4) * (height - 2 * padding)
      val = max_val - (i / 4) * (max_val - min_val)
      """
      <line x1="#{padding}" y1="#{round(y)}" x2="#{width - padding}" y2="#{round(y)}" class="grid"/>
      <text x="#{padding - 5}" y="#{round(y) + 4}" text-anchor="end" class="axis-label">#{round(val)}</text>
      """
    end

    # Vertical grid lines
    v_lines = for i <- 0..5 do
      x = padding + (i / 5) * (width - 2 * padding)
      gen = round(1 + (i / 5) * (generations - 1))
      """
      <line x1="#{round(x)}" y1="#{padding}" x2="#{round(x)}" y2="#{height - padding}" class="grid"/>
      <text x="#{round(x)}" y="#{height - padding + 15}" text-anchor="middle" class="axis-label">#{gen}</text>
      """
    end

    Enum.join(h_lines ++ v_lines, "\n")
  end

  defp format_num(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 1)
  defp format_num(n), do: "#{n}"

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
