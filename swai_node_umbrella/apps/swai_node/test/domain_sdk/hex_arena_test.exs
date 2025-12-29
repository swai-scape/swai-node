defmodule SwaiNode.DomainSDK.HexArenaTest do
  use ExUnit.Case, async: true

  alias SwaiNode.DomainSDK.{
    ForagerAgentDefinition,
    ForagerEvaluator,
    HexArenaEnvironment,
    ForagerBridge
  }

  alias SwaiNode.DomainSDK.Sensors.{
    VisionSensor,
    HearingSensor,
    SmellSensor,
    StateSensor
  }

  alias SwaiNode.DomainSDK.Actuators.{
    MovementActuator,
    SignalActuator,
    AttackActuator
  }

  describe "ForagerAgentDefinition" do
    test "validates correctly" do
      assert :ok = :agent_definition.validate(ForagerAgentDefinition)
    end

    test "returns binary name" do
      assert <<"forager_agent">> = ForagerAgentDefinition.name()
    end

    test "returns correct topology" do
      assert {29, [32, 16], 9} = ForagerAgentDefinition.network_topology()
    end
  end

  describe "Sensors" do
    setup do
      agent_state = %{
        id: make_ref(),
        hex: {0, 0},
        energy: 100.0,
        age: 10,
        signal: 0.5,
        generation: 1
      }

      env_state = %{
        food: %{{1, 0} => %{energy: 20.0}},
        walls: MapSet.new([{2, 0}]),
        agents: %{},
        arena_radius: 10
      }

      {:ok, agent: agent_state, env: env_state}
    end

    test "VisionSensor validates and returns 18 values", %{agent: agent, env: env} do
      assert :ok = :agent_sensor.validate(VisionSensor)
      assert 18 = VisionSensor.input_count()
      values = VisionSensor.read(agent, env)
      assert length(values) == 18
    end

    test "HearingSensor validates and returns 4 values", %{agent: agent, env: env} do
      assert :ok = :agent_sensor.validate(HearingSensor)
      assert 4 = HearingSensor.input_count()
      values = HearingSensor.read(agent, env)
      assert length(values) == 4
    end

    test "SmellSensor validates and returns 3 values", %{agent: agent, env: env} do
      assert :ok = :agent_sensor.validate(SmellSensor)
      assert 3 = SmellSensor.input_count()
      values = SmellSensor.read(agent, env)
      assert length(values) == 3
    end

    test "StateSensor validates and returns 4 values", %{agent: agent, env: env} do
      assert :ok = :agent_sensor.validate(StateSensor)
      assert 4 = StateSensor.input_count()
      values = StateSensor.read(agent, env)
      assert length(values) == 4
    end

    test "total sensor inputs match topology" do
      total = VisionSensor.input_count() +
              HearingSensor.input_count() +
              SmellSensor.input_count() +
              StateSensor.input_count()
      {inputs, _, _} = ForagerAgentDefinition.network_topology()
      assert total == inputs
    end
  end

  describe "Actuators" do
    test "MovementActuator validates and returns action" do
      assert :ok = :agent_actuator.validate(MovementActuator)
      assert 7 = MovementActuator.output_count()

      outputs = [0.5, 0.3, 0.1, 0.2, 0.1, 0.1, 0.0]
      assert {:ok, action} = MovementActuator.act(outputs, %{}, %{})
      assert action.type == :move
      assert is_atom(action.direction)
    end

    test "SignalActuator validates and returns action" do
      assert :ok = :agent_actuator.validate(SignalActuator)
      assert 1 = SignalActuator.output_count()

      assert {:ok, action} = SignalActuator.act([0.7], %{}, %{})
      assert action.type == :signal
      assert action.strength == 0.7
    end

    test "AttackActuator validates and returns action" do
      assert :ok = :agent_actuator.validate(AttackActuator)
      assert 1 = AttackActuator.output_count()

      assert {:ok, action} = AttackActuator.act([0.6], %{}, %{})
      assert action.type == :attack
      assert action.attacking == true
    end

    test "total actuator outputs match topology" do
      total = MovementActuator.output_count() +
              SignalActuator.output_count() +
              AttackActuator.output_count()
      {_, _, outputs} = ForagerAgentDefinition.network_topology()
      assert total == outputs
    end
  end

  describe "HexArenaEnvironment" do
    test "validates correctly" do
      assert :ok = :agent_environment.validate(HexArenaEnvironment)
    end

    test "init creates environment state" do
      assert {:ok, env_state} = HexArenaEnvironment.init(%{max_ticks: 100})
      assert env_state.max_ticks == 100
      assert env_state.tick == 0
      assert is_map(env_state.food)
    end

    test "spawn_agent creates agent state" do
      {:ok, env_state} = HexArenaEnvironment.init(%{})
      {:ok, agent_state, _env} = HexArenaEnvironment.spawn_agent(:test_agent, env_state)

      assert agent_state.id == :test_agent
      assert agent_state.hex == {0, 0}
      assert agent_state.energy == 150.0
    end
  end

  describe "ForagerEvaluator" do
    test "validates correctly" do
      assert :ok = :agent_evaluator.validate(ForagerEvaluator)
    end

    test "calculates fitness from metrics" do
      metrics = %{ticks_survived: 100, food_eaten: 3, kills: 1}
      fitness = ForagerEvaluator.calculate_fitness(metrics)
      # 100 * 0.1 + 3 * 150 + 1 * 100 = 560
      assert fitness == 560.0
    end

    test "returns fitness components" do
      metrics = %{ticks_survived: 100, food_eaten: 2, kills: 0}
      components = ForagerEvaluator.fitness_components(metrics)
      assert components.survival == 10.0
      assert components.food == 300.0
      assert components.kills == 0.0
    end
  end

  describe "ForagerBridge" do
    test "creates valid bridge" do
      assert {:ok, bridge} = ForagerBridge.new()
      assert :ok = ForagerBridge.validate(bridge)
    end

    test "bridge has correct topology" do
      assert {29, [32, 16], 9} = ForagerBridge.topology()
    end
  end
end
