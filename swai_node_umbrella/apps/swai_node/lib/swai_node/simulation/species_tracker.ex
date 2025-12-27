defmodule SwaiNode.Simulation.SpeciesTracker do
  @moduledoc """
  Tracks species formation through network weight similarity.

  Species are clusters of agents with similar neural network weights.
  Uses k-means style clustering with dynamic species creation.

  Species emerge when:
  - Agents with similar strategies (weights) survive and reproduce
  - Reproductive isolation through geographic/behavioral separation
  - Distinct adaptations to different niches (food zones, etc.)
  """

  alias SwaiNode.Simulation.AgentBrain

  @doc """
  Calculate compatibility distance between two networks.
  Uses Euclidean distance on weight vectors, normalized by size.
  """
  @spec compatibility_distance(term(), term()) :: float()
  def compatibility_distance(network1, network2) do
    weights1 = AgentBrain.get_weights(network1)
    weights2 = AgentBrain.get_weights(network2)

    # Euclidean distance normalized by vector length
    squared_diff = Enum.zip(weights1, weights2)
                   |> Enum.map(fn {w1, w2} -> :math.pow(w1 - w2, 2) end)
                   |> Enum.sum()

    :math.sqrt(squared_diff) / :math.sqrt(length(weights1))
  end

  @doc """
  Assign species to all agents based on network similarity.

  Uses a greedy clustering approach:
  1. Sort agents by fitness (best first)
  2. Best agent of each new cluster becomes the species representative
  3. Agents within threshold distance join existing species
  4. Agents beyond threshold form new species

  Returns updated agent map with species_id assigned.
  """
  @spec assign_species(map(), float()) :: {map(), map()}
  def assign_species(agents, threshold \\ 0.5) when is_map(agents) do
    agent_list = agents
                 |> Map.values()
                 |> Enum.sort_by(& &1.fitness, :desc)

    {updated_agents, species_info} = assign_species_recursive(agent_list, [], %{}, threshold, 1)

    agents_map = updated_agents
                 |> Enum.map(fn agent -> {agent.id, agent} end)
                 |> Map.new()

    {agents_map, species_info}
  end

  defp assign_species_recursive([], agents_acc, species_acc, _threshold, _next_id) do
    {agents_acc, species_acc}
  end

  defp assign_species_recursive([agent | rest], agents_acc, species_acc, threshold, next_id) do
    # Find closest existing species
    {closest_species, closest_distance} = find_closest_species(agent, species_acc)

    {new_agents_acc, new_species_acc, new_next_id} =
      if closest_species != nil and closest_distance < threshold do
        # Join existing species
        updated_agent = %{agent | species_id: closest_species}
        updated_species = Map.update!(species_acc, closest_species, fn info ->
          %{info | count: info.count + 1, total_fitness: info.total_fitness + agent.fitness}
        end)
        {[updated_agent | agents_acc], updated_species, next_id}
      else
        # Create new species
        species_id = "sp#{next_id}"
        updated_agent = %{agent | species_id: species_id}
        new_species = %{
          id: species_id,
          representative: agent.network,
          count: 1,
          total_fitness: agent.fitness,
          founder_generation: agent.generation,
          color_hue: rem(next_id * 47, 360)  # Golden angle for color distribution
        }
        {[updated_agent | agents_acc], Map.put(species_acc, species_id, new_species), next_id + 1}
      end

    assign_species_recursive(rest, new_agents_acc, new_species_acc, threshold, new_next_id)
  end

  defp find_closest_species(_agent, species) when map_size(species) == 0 do
    {nil, :infinity}
  end

  defp find_closest_species(agent, species) do
    species
    |> Enum.map(fn {id, info} ->
      distance = compatibility_distance(agent.network, info.representative)
      {id, distance}
    end)
    |> Enum.min_by(fn {_id, dist} -> dist end)
  end

  @doc """
  Get species statistics for dashboard display.
  """
  @spec get_species_stats(map()) :: list(map())
  def get_species_stats(species_info) when is_map(species_info) do
    total_count = species_info
                  |> Map.values()
                  |> Enum.map(& &1.count)
                  |> Enum.sum()
                  |> max(1)

    species_info
    |> Enum.map(fn {id, info} ->
      %{
        id: id,
        count: info.count,
        percentage: round(info.count / total_count * 100),
        avg_fitness: Float.round(info.total_fitness / max(info.count, 1), 1),
        color_hue: info.color_hue,
        founder_gen: info.founder_generation
      }
    end)
    |> Enum.sort_by(& &1.count, :desc)
    |> Enum.take(8)  # Top 8 species for display
  end

  @doc """
  Quick species diversity metric (0-1).
  Higher means more even distribution across species.
  Uses Shannon entropy normalized by max entropy.
  """
  @spec diversity_index(map()) :: float()
  def diversity_index(species_info) when is_map(species_info) do
    total = species_info
            |> Map.values()
            |> Enum.map(& &1.count)
            |> Enum.sum()

    if total == 0 or map_size(species_info) <= 1 do
      0.0
    else
      # Shannon entropy
      entropy = species_info
                |> Map.values()
                |> Enum.map(fn info ->
                  p = info.count / total
                  if p > 0, do: -p * :math.log2(p), else: 0.0
                end)
                |> Enum.sum()

      # Normalize by max entropy (log2 of species count)
      max_entropy = :math.log2(map_size(species_info))
      Float.round(entropy / max_entropy, 2)
    end
  end
end
