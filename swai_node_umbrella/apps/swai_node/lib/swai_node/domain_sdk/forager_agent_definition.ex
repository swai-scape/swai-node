defmodule SwaiNode.DomainSDK.ForagerAgentDefinition do
  @moduledoc """
  Definition for a foraging agent in the hex arena.

  Implements the `agent_definition` behaviour from the Domain SDK.

  This agent forages for food, avoids walls, and can interact with
  other agents through signals and combat.

  ## Network Topology

  - **Inputs (29)**: Vision (18) + Hearing (4) + Smell (3) + State (4)
  - **Hidden**: [32, 16] neurons
  - **Outputs (9)**: Movement (7) + Signal (1) + Attack (1)
  """

  # Implements :agent_definition behaviour (Erlang)

  def name, do: <<"forager_agent">>

  def version, do: <<"1.0.0">>

  def network_topology do
    # {Inputs, HiddenLayers, Outputs}
    {29, [32, 16], 9}
  end
end
