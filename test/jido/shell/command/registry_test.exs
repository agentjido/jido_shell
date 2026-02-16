defmodule Jido.Shell.Command.RegistryTest do
  use Jido.Shell.Case, async: true

  alias Jido.Shell.Command.Registry

  describe "lookup/1" do
    test "returns module for known command" do
      assert {:ok, Jido.Shell.Command.Echo} = Registry.lookup("echo")
    end

    test "returns module for pwd command" do
      assert {:ok, Jido.Shell.Command.Pwd} = Registry.lookup("pwd")
    end

    test "returns error for unknown command" do
      assert {:error, :not_found} = Registry.lookup("unknown_cmd")
    end
  end

  describe "list/0" do
    test "returns list of available command names" do
      names = Registry.list()
      assert "echo" in names
      assert "pwd" in names
      assert "bash" in names
    end
  end

  describe "commands/0" do
    test "returns map of command name to module" do
      commands = Registry.commands()
      assert is_map(commands)
      assert commands["echo"] == Jido.Shell.Command.Echo
      assert commands["pwd"] == Jido.Shell.Command.Pwd
      assert commands["bash"] == Jido.Shell.Command.Bash
    end
  end
end
