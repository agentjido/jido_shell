defmodule Jido.Shell.SupervisionTest do
  use Jido.Shell.Case, async: true

  describe "supervision tree" do
    test "SessionRegistry is running" do
      assert Process.whereis(Jido.Shell.SessionRegistry) != nil
    end

    test "SessionSupervisor is running" do
      assert Process.whereis(Jido.Shell.SessionSupervisor) != nil
    end

    test "CommandTaskSupervisor is running" do
      assert Process.whereis(Jido.Shell.CommandTaskSupervisor) != nil
    end

    test "Jido.Shell.Supervisor is running" do
      assert Process.whereis(Jido.Shell.Supervisor) != nil
    end
  end
end
