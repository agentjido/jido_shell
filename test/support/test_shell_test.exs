defmodule Jido.Shell.TestShellTest do
  use Jido.Shell.Case, async: false

  alias Jido.Shell.TestShell

  defp missing_shell() do
    %TestShell{
      session_id: "missing-session",
      workspace_id: "missing-workspace",
      owner: self()
    }
  end

  describe "error wrappers" do
    test "run!/3 raises on command errors" do
      assert_raise RuntimeError, ~r/Command failed/, fn ->
        TestShell.run!(missing_shell(), "echo hi")
      end
    end

    test "cwd/1 raises when state lookup fails" do
      assert_raise RuntimeError, ~r/Failed to get cwd/, fn ->
        TestShell.cwd(missing_shell())
      end
    end

    test "read_file!/2 raises on missing session" do
      assert_raise RuntimeError, ~r/Failed to read/, fn ->
        TestShell.read_file!(missing_shell(), "/missing.txt")
      end
    end

    test "ls/2 and ls!/2 propagate errors" do
      assert {:error, %Jido.Shell.Error{code: {:session, :not_found}}} = TestShell.ls(missing_shell())

      assert_raise RuntimeError, ~r/Failed to list/, fn ->
        TestShell.ls!(missing_shell())
      end
    end

    test "subscribe/unsubscribe/run_async/cancel return explicit errors on missing sessions" do
      assert {:error, %Jido.Shell.Error{code: {:session, :not_found}}} = TestShell.subscribe(missing_shell())
      assert {:error, %Jido.Shell.Error{code: {:session, :not_found}}} = TestShell.unsubscribe(missing_shell())
      assert {:error, %Jido.Shell.Error{code: {:session, :not_found}}} = TestShell.run_async(missing_shell(), "echo hi")
      assert {:error, %Jido.Shell.Error{code: {:session, :not_found}}} = TestShell.cancel(missing_shell())
    end
  end

  describe "helpers" do
    test "run_all/3 executes command lists" do
      shell = TestShell.start!()

      assert [
               {"echo one", {:ok, "one"}},
               {"echo two", {:ok, "two"}}
             ] = TestShell.run_all(shell, ["echo one", "echo two"])
    end

    test "await_event/3 supports timeout and exact matching" do
      shell = TestShell.start!()

      assert {:error, :timeout} = TestShell.await_event(shell, :command_done, 10)

      send(self(), {:jido_shell_session, shell.session_id, {:output, "exact"}})
      assert {:ok, {:output, "exact"}} = TestShell.await_event(shell, {:output, "exact"}, 50)
    end

    test "collect_events/2 handles cancelled and crashed terminal events" do
      shell = TestShell.start!()

      send(self(), {:jido_shell_session, shell.session_id, :command_cancelled})
      assert [:command_cancelled] = TestShell.collect_events(shell, 50)

      send(self(), {:jido_shell_session, shell.session_id, {:command_crashed, :boom}})
      assert [{:command_crashed, :boom}] = TestShell.collect_events(shell, 50)
    end

    test "exists?/2 resolves relative paths from cwd" do
      shell = TestShell.start!()
      :ok = TestShell.write_file(shell, "/exists.txt", "ok")

      assert TestShell.exists?(shell, "exists.txt")
    end

    test "subscribe/unsubscribe success paths return :ok" do
      shell = TestShell.start!()

      assert :ok = TestShell.subscribe(shell)
      assert :ok = TestShell.unsubscribe(shell)
    end
  end
end
