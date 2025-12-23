defmodule Kodo.SupervisionTest do
  use Kodo.Case, async: true

  describe "supervision tree" do
    test "SessionRegistry is running" do
      assert Process.whereis(Kodo.SessionRegistry) != nil
    end

    test "SessionSupervisor is running" do
      assert Process.whereis(Kodo.SessionSupervisor) != nil
    end

    test "CommandTaskSupervisor is running" do
      assert Process.whereis(Kodo.CommandTaskSupervisor) != nil
    end

    test "Kodo.Supervisor is running" do
      assert Process.whereis(Kodo.Supervisor) != nil
    end
  end
end
