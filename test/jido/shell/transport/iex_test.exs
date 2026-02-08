defmodule Jido.Shell.Transport.IExTest do
  use Jido.Shell.Case, async: false

  alias Jido.Shell.Transport.IEx
  alias Jido.Shell.Session
  alias Jido.Shell.SessionServer

  describe "attach/1" do
    test "returns error for non-existent session" do
      assert {:error, :not_found} = IEx.attach("nonexistent-session")
    end
  end

  describe "event handling" do
    test "receives events from session" do
      workspace_id = :"test_ws_#{System.unique_integer([:positive])}"
      {:ok, session_id} = Session.start_with_vfs(workspace_id)
      :ok = SessionServer.subscribe(session_id, self())

      :ok = SessionServer.run_command(session_id, "echo hello")

      assert_receive {:jido_shell_session, ^session_id, {:command_started, "echo hello"}}
      assert_receive {:jido_shell_session, ^session_id, {:output, "hello\n"}}
      assert_receive {:jido_shell_session, ^session_id, :command_done}
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
