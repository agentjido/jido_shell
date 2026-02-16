defmodule Jido.Shell.Transport.IExTest do
  use Jido.Shell.Case, async: false

  import ExUnit.CaptureIO

  alias Jido.Shell.Error
  alias Jido.Shell.ShellSession
  alias Jido.Shell.Transport.IEx
  alias Jido.Shell.ShellSessionServer

  defp start_session!() do
    workspace_id = "test_ws_#{System.unique_integer([:positive])}"
    {:ok, session_id} = ShellSession.start_with_vfs(workspace_id)

    on_exit(fn ->
      _ = ShellSession.stop(session_id)
      _ = ShellSession.teardown_workspace(workspace_id)
    end)

    {workspace_id, session_id}
  end

  describe "attach/1" do
    test "returns error for non-existent session" do
      assert {:error, :not_found} = IEx.attach("nonexistent-session")
    end

    test "attaches and exits cleanly" do
      {_workspace_id, session_id} = start_session!()

      output =
        capture_io("exit\n", fn ->
          assert :ok = IEx.attach(session_id)
        end)

      assert output =~ "Attached to session"
      assert output =~ "Goodbye!"
    end
  end

  describe "event handling" do
    test "receives events from session" do
      {_workspace_id, session_id} = start_session!()
      {:ok, :subscribed} = ShellSessionServer.subscribe(session_id, self())

      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "echo hello")

      assert_receive {:jido_shell_session, ^session_id, {:command_started, "echo hello"}}
      assert_receive {:jido_shell_session, ^session_id, {:output, "hello\n"}}
      assert_receive {:jido_shell_session, ^session_id, :command_done}
    end

    test "starts with an existing session and handles empty input" do
      {workspace_id, session_id} = start_session!()

      output =
        capture_io("\nquit\n", fn ->
          assert :ok = IEx.start(workspace_id, session_id: session_id)
        end)

      assert output =~ "Jido.Shell v"
      assert output =~ "Goodbye!"
    end

    test "returns explicit error when start_with_vfs fails for workspace" do
      assert {:error, %Error{code: {:session, :invalid_workspace_id}}} = IEx.start("")
    end

    test "handles EOF input" do
      {workspace_id, session_id} = start_session!()

      output =
        capture_io(fn ->
          assert :ok = IEx.start(workspace_id, session_id: session_id, line_reader: fn _ -> :eof end)
        end)

      assert output =~ "Goodbye!"
    end

    test "handles input read errors" do
      {_workspace_id, session_id} = start_session!()

      output =
        capture_io(fn ->
          assert :ok = IEx.attach(session_id, line_reader: fn _ -> {:error, :io_failure} end)
        end)

      assert output =~ "Input error, exiting."
    end

    test "prints output and cwd changes while running commands" do
      {workspace_id, session_id} = start_session!()

      output =
        capture_io("echo hello\nmkdir /tmp\ncd /tmp\npwd\nexit\n", fn ->
          assert :ok = IEx.start(workspace_id, session_id: session_id)
        end)

      assert output =~ "hello"
      assert output =~ "/tmp"
    end

    test "prints command errors from session events" do
      {workspace_id, session_id} = start_session!()

      output =
        capture_io("unknown_cmd\nexit\n", fn ->
          assert :ok = IEx.start(workspace_id, session_id: session_id)
        end)

      assert output =~ "Error:"
      assert output =~ "unknown_command"
    end

    test "prints synthetic cancelled event" do
      {workspace_id, session_id} = start_session!()
      parent = self()

      spawn(fn ->
        Process.sleep(25)
        send(parent, {:jido_shell_session, session_id, :command_cancelled})
      end)

      output =
        capture_io("sleep 1\nexit\n", fn ->
          assert :ok = IEx.start(workspace_id, session_id: session_id)
        end)

      assert output =~ "Cancelled"
    end

    test "prints synthetic command crash events" do
      {workspace_id, session_id} = start_session!()
      parent = self()

      spawn(fn ->
        Process.sleep(25)
        send(parent, {:jido_shell_session, session_id, {:command_crashed, :boom}})
      end)

      output =
        capture_io("sleep 1\nexit\n", fn ->
          assert :ok = IEx.start(workspace_id, session_id: session_id)
        end)

      assert output =~ "Command crashed: :boom"
    end

    test "prints generic non-struct errors" do
      {workspace_id, session_id} = start_session!()
      parent = self()

      spawn(fn ->
        Process.sleep(25)
        send(parent, {:jido_shell_session, session_id, {:error, :oops}})
      end)

      output =
        capture_io("sleep 1\nexit\n", fn ->
          assert :ok = IEx.start(workspace_id, session_id: session_id)
        end)

      assert output =~ "Error: :oops"
    end

    test "prints timeout when no completion event arrives in configured window" do
      {workspace_id, session_id} = start_session!()

      output =
        capture_io("sleep 1\nexit\n", fn ->
          assert :ok =
                   IEx.start(workspace_id,
                     session_id: session_id,
                     wait_timeout_ms: 10
                   )
        end)

      assert output =~ "Timeout waiting for command"
    end

    test "falls back to default timeout for invalid timeout options" do
      {workspace_id, session_id} = start_session!()

      output =
        capture_io(fn ->
          assert :ok =
                   IEx.start(workspace_id,
                     session_id: session_id,
                     wait_timeout_ms: :invalid,
                     line_reader: fn _ -> "exit\n" end
                   )
        end)

      assert output =~ "Goodbye!"
    end

    test "prints errors when command submission fails during loop" do
      {workspace_id, session_id} = start_session!()

      reader = fn _prompt ->
        case Process.get(:iex_step, 0) do
          0 ->
            Process.put(:iex_step, 1)
            :ok = ShellSession.stop(session_id)
            "echo hi\n"

          _ ->
            "exit\n"
        end
      end

      output =
        capture_io(fn ->
          assert :ok = IEx.start(workspace_id, session_id: session_id, line_reader: reader)
        end)

      assert output =~ "Error:"
    end
  end

  describe "help command integration" do
    test "registry returns all commands for help" do
      commands = Jido.Shell.Command.Registry.list()

      assert "echo" in commands
      assert "pwd" in commands
      assert "ls" in commands
      assert "cat" in commands
      assert "cd" in commands
      assert "mkdir" in commands
      assert "write" in commands
      assert "help" in commands
    end
  end
end
