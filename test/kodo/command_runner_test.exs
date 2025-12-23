defmodule Kodo.CommandRunnerTest do
  use Kodo.Case, async: true

  alias Kodo.CommandRunner
  alias Kodo.Session.State

  setup do
    {:ok, state} = State.new(%{id: "test-session", workspace_id: :test, cwd: "/home/user"})
    {:ok, state: state}
  end

  describe "execute/3" do
    test "executes echo command successfully", %{state: state} do
      emit = fn event -> send(self(), {:emit, event}) end

      result = CommandRunner.execute(state, "echo hello world", emit)

      assert {:ok, nil} = result
      assert_receive {:emit, {:output, "hello world\n"}}
    end

    test "executes pwd command successfully", %{state: state} do
      emit = fn event -> send(self(), {:emit, event}) end

      result = CommandRunner.execute(state, "pwd", emit)

      assert {:ok, nil} = result
      assert_receive {:emit, {:output, "/home/user\n"}}
    end

    test "returns error for unknown command", %{state: state} do
      emit = fn _event -> :ok end

      result = CommandRunner.execute(state, "unknown_cmd", emit)

      assert {:error, error} = result
      assert error.code == {:shell, :unknown_command}
      assert error.context.name == "unknown_cmd"
    end

    test "returns error for empty command", %{state: state} do
      emit = fn _event -> :ok end

      result = CommandRunner.execute(state, "", emit)

      assert {:error, :empty_command} = result
    end
  end

  describe "run/4" do
    test "sends events to session pid", %{state: state} do
      session_pid = self()

      spawn(fn ->
        CommandRunner.run(session_pid, state, "echo test", [])
      end)

      assert_receive {:command_event, {:output, "test\n"}}
      assert_receive {:command_finished, {:ok, nil}}
    end

    test "sends error result for unknown command", %{state: state} do
      session_pid = self()

      spawn(fn ->
        CommandRunner.run(session_pid, state, "bad_cmd", [])
      end)

      assert_receive {:command_finished, {:error, %Kodo.Error{code: {:shell, :unknown_command}}}}
    end
  end
end
