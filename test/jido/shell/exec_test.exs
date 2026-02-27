defmodule Jido.Shell.ExecTest do
  use ExUnit.Case, async: true

  alias Jido.Shell.Exec

  defmodule FakeShellAgent do
    def run(session_id, command, opts) do
      send(self(), {:shell_run, session_id, command, opts})
      Process.get(:exec_fake_result, {:ok, ""})
    end
  end

  test "run/4 trims output and uses default timeout" do
    Process.put(:exec_fake_result, {:ok, "  hello world\n"})

    assert {:ok, "hello world"} = Exec.run(FakeShellAgent, "sess-1", "echo hello")

    assert_receive {:shell_run, "sess-1", "echo hello", [timeout: 60_000]}
  end

  test "run/4 passes explicit timeout" do
    Process.put(:exec_fake_result, {:ok, "done\n"})

    assert {:ok, "done"} = Exec.run(FakeShellAgent, "sess-1", "echo done", timeout: 1_500)

    assert_receive {:shell_run, "sess-1", "echo done", [timeout: 1_500]}
  end

  test "run/4 passes through errors" do
    Process.put(:exec_fake_result, {:error, :boom})

    assert {:error, :boom} = Exec.run(FakeShellAgent, "sess-1", "bad command")
  end

  test "run_in_dir/5 wraps command with escaped cwd" do
    Process.put(:exec_fake_result, {:ok, "ok\n"})

    assert {:ok, "ok"} =
             Exec.run_in_dir(
               FakeShellAgent,
               "sess-1",
               "/tmp/it's/quoted",
               "echo ok",
               timeout: 50
             )

    assert_receive {:shell_run, "sess-1", command, [timeout: 50]}
    assert command == "cd '/tmp/it'\\''s/quoted' && echo ok"
  end

  test "escape_path/1 escapes single quotes" do
    assert Exec.escape_path("/a'b/c") == "'/a'\\''b/c'"
  end
end
