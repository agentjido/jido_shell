defmodule Jido.Shell.IdentifierMigrationTest do
  use Jido.Shell.Case, async: false

  alias Jido.Shell.Agent
  alias Jido.Shell.ShellSession
  alias Jido.Shell.ShellSessionServer
  alias Jido.Shell.VFS

  test "accepts binary workspace identifiers across public APIs" do
    workspace_id = "identifier_ws_#{System.unique_integer([:positive])}"

    assert {:ok, session_id} = ShellSession.start(workspace_id)
    assert {:ok, _state} = ShellSessionServer.get_state(session_id)
    assert :ok = ShellSession.stop(session_id)
  end

  test "rejects atom workspace identifiers with typed errors" do
    assert {:error, %Jido.Shell.Error{code: {:session, :invalid_workspace_id}}} = ShellSession.start(:legacy_workspace)
    assert {:error, %Jido.Shell.Error{code: {:session, :invalid_workspace_id}}} = Agent.new(:legacy_workspace)

    assert {:error, %Jido.Shell.Error{code: {:session, :invalid_workspace_id}}} =
             VFS.mount(:legacy_workspace, "/", Jido.VFS.Adapter.InMemory, name: "legacy")
  end

  test "rejects non-binary session identifiers with typed errors" do
    assert {:error, %Jido.Shell.Error{code: {:session, :invalid_session_id}}} =
             ShellSessionServer.get_state(:legacy_session_id)

    assert {:error, %Jido.Shell.Error{code: {:session, :invalid_session_id}}} =
             ShellSessionServer.run_command(:legacy_session_id, "echo hi")
  end
end
