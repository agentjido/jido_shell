defmodule Jido.Shell.SessionCompatibilityTest do
  use Jido.Shell.Case, async: true

  @session_shim :"Elixir.Jido.Shell.Session"
  @session_server_shim :"Elixir.Jido.Shell.SessionServer"
  @state_shim :"Elixir.Jido.Shell.Session.State"

  test "Session shim delegates start/lookup/stop" do
    workspace_id = "compat_ws_#{System.unique_integer([:positive])}"

    assert {:ok, session_id} = apply(@session_shim, :start, [workspace_id, []])
    assert {:ok, pid} = apply(@session_shim, :lookup, [session_id])
    assert is_pid(pid)
    assert :ok = apply(@session_shim, :stop, [session_id])
  end

  test "SessionServer shim delegates run_command/cancel/get_state" do
    workspace_id = "compat_ws_server_#{System.unique_integer([:positive])}"
    assert {:ok, session_id} = apply(@session_shim, :start, [workspace_id, []])

    on_exit(fn ->
      _ = Jido.Shell.ShellSession.stop(session_id)
    end)

    assert {:ok, %Jido.Shell.ShellSession.State{}} =
             apply(@session_server_shim, :get_state, [session_id])

    assert {:ok, :accepted} = apply(@session_server_shim, :run_command, [session_id, "sleep 5", []])
    assert {:ok, :cancelled} = apply(@session_server_shim, :cancel, [session_id])
  end

  test "Session.State shim delegates new/new!/schema" do
    schema = apply(@state_shim, :schema, [])
    assert is_struct(schema)

    assert {:ok, %Jido.Shell.ShellSession.State{} = state} =
             apply(@state_shim, :new, [%{id: "compat-sess", workspace_id: "compat_ws"}])

    assert state.__struct__ == Jido.Shell.ShellSession.State

    assert %Jido.Shell.ShellSession.State{} =
             apply(@state_shim, :new!, [%{id: "compat-sess-2", workspace_id: "compat_ws"}])
  end
end
