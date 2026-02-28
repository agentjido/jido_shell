defmodule Jido.Shell.EnvironmentTest do
  use Jido.Shell.Case, async: true

  alias Jido.Shell.Environment
  alias Jido.Shell.Environment.Sprite, as: SpriteEnv

  describe "Environment behaviour" do
    test "defines provision/3 callback" do
      assert {:provision, 3} in Environment.behaviour_info(:callbacks)
    end

    test "defines teardown/2 callback" do
      assert {:teardown, 2} in Environment.behaviour_info(:callbacks)
    end

    test "defines status/2 as optional callback" do
      assert {:status, 2} in Environment.behaviour_info(:optional_callbacks)
    end
  end

  describe "Environment.Sprite" do
    test "implements Environment behaviour" do
      behaviours =
        SpriteEnv.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Environment in behaviours
    end

    test "exports provision/3" do
      assert function_exported?(SpriteEnv, :provision, 3)
    end

    test "exports teardown/2" do
      assert function_exported?(SpriteEnv, :teardown, 2)
    end

    test "does not implement optional status/2" do
      refute function_exported?(SpriteEnv, :status, 2)
    end
  end
end
