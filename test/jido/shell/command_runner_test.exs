defmodule Jido.Shell.CommandRunnerTest do
  use Jido.Shell.Case, async: true

  alias Jido.Shell.CommandRunner
  alias Jido.Shell.ShellSession.State

  setup do
    {:ok, state} = State.new(%{id: "test-session", workspace_id: "test", cwd: "/home/user"})
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

      assert {:error, %Jido.Shell.Error{code: {:shell, :empty_command}}} = result
    end

    test "returns syntax errors for malformed command lines", %{state: state} do
      emit = fn _event -> :ok end

      result = CommandRunner.execute(state, ~s(echo "unterminated), emit)

      assert {:error, %Jido.Shell.Error{code: {:shell, :syntax_error}}} = result
    end

    test "returns validation errors when argument schema parsing fails", %{state: state} do
      emit = fn _event -> :ok end

      result = CommandRunner.execute(state, "sleep 1 2", emit)

      assert {:error, %Jido.Shell.Error{code: {:validation, :invalid_args}}} = result
    end

    test "supports semicolon chaining and continues after errors", %{state: state} do
      emit = fn event -> send(self(), {:emit, event}) end

      result = CommandRunner.execute(state, "unknown_cmd; echo recovered", emit)

      assert {:ok, nil} = result
      assert_receive {:emit, {:output, "recovered\n"}}
    end

    test "supports and-if chaining and short-circuits on error", %{state: state} do
      emit = fn event -> send(self(), {:emit, event}) end

      result = CommandRunner.execute(state, "unknown_cmd && echo skipped", emit)

      assert {:error, %Jido.Shell.Error{code: {:shell, :unknown_command}}} = result
      refute_receive {:emit, {:output, "skipped\n"}}
    end

    test "preserves state updates across chained commands", %{state: state} do
      emit = fn event -> send(self(), {:emit, event}) end

      result = CommandRunner.execute(state, "env FOO=bar && env FOO", emit)

      assert {:ok, {:state_update, %{env: %{"FOO" => "bar"}}}} = result
      assert_receive {:emit, {:output, "FOO=bar\n"}}
    end
  end

  describe "run/4" do
    test "sends events to session pid", %{state: state} do
      session_pid = self()

      spawn(fn ->
        CommandRunner.run(session_pid, state, "echo test", [])
      end)

      assert_receive {:command_event, {:output, "test\n"}}, 1_000
      assert_receive {:command_finished, {:ok, nil}}, 1_000
    end

    test "sends error result for unknown command", %{state: state} do
      session_pid = self()

      spawn(fn ->
        CommandRunner.run(session_pid, state, "bad_cmd", [])
      end)

      assert_receive {:command_finished, {:error, %Jido.Shell.Error{code: {:shell, :unknown_command}}}}, 1_000
    end

    test "applies execution context options", %{state: state} do
      session_pid = self()

      spawn(fn ->
        CommandRunner.run(
          session_pid,
          state,
          "bash -c \"curl https://example.com\"",
          execution_context: %{network: %{allow_domains: ["example.com"]}}
        )
      end)

      assert_receive {:command_finished, {:error, %Jido.Shell.Error{code: {:shell, :unknown_command}}}}, 1_000
    end

    test "enforces runtime limits from execution context", %{state: state} do
      session_pid = self()

      spawn(fn ->
        CommandRunner.run(
          session_pid,
          state,
          "sleep 2",
          execution_context: %{limits: %{max_runtime_ms: 100}}
        )
      end)

      assert_receive {:command_finished, {:error, %Jido.Shell.Error{code: {:command, :runtime_limit_exceeded}}}}, 1_000
    end

    test "accepts runtime and output limits as positive strings", %{state: state} do
      session_pid = self()

      spawn(fn ->
        CommandRunner.run(
          session_pid,
          state,
          "echo ok",
          execution_context: %{limits: %{"max_runtime_ms" => "1000", "max_output_bytes" => "1000"}}
        )
      end)

      assert_receive {:command_event, {:output, "ok\n"}}, 1_000
      assert_receive {:command_finished, {:ok, nil}}, 1_000
    end

    test "ignores invalid string limits and non-keyword execution contexts", %{state: state} do
      session_pid = self()

      spawn(fn ->
        CommandRunner.run(
          session_pid,
          state,
          "echo pass",
          execution_context: [limits: [{"max_runtime_ms", "bad"}], max_output_bytes: "bad"]
        )
      end)

      assert_receive {:command_event, {:output, "pass\n"}}, 1_000
      assert_receive {:command_finished, {:ok, nil}}, 1_000
    end

    test "enforces output size limits from execution context", %{state: state} do
      session_pid = self()

      spawn(fn ->
        CommandRunner.run(
          session_pid,
          state,
          "seq 10 0",
          execution_context: %{limits: %{max_output_bytes: 3}}
        )
      end)

      assert_receive {:command_finished, {:error, %Jido.Shell.Error{code: {:command, :output_limit_exceeded}}}}, 1_000
    end
  end
end
