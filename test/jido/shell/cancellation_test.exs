defmodule Jido.Shell.CancellationTest do
  use Jido.Shell.Case, async: true

  alias Jido.Shell.Session
  alias Jido.Shell.SessionServer

  setup do
    workspace_id = :"test_ws_#{System.unique_integer([:positive])}"
    {:ok, session_id} = Session.start(workspace_id)
    :ok = SessionServer.subscribe(session_id, self())

    {:ok, session_id: session_id}
  end

  describe "cancel/1" do
    test "cancels running command", %{session_id: session_id} do
      :ok = SessionServer.run_command(session_id, "sleep 10")

      assert_receive {:jido_shell_session, _, {:command_started, "sleep 10"}}
      assert_receive {:jido_shell_session, _, {:output, "Sleeping for 10 seconds...\n"}}

      :ok = SessionServer.cancel(session_id)

      assert_receive {:jido_shell_session, _, :command_cancelled}

      {:ok, state} = SessionServer.get_state(session_id)
      refute state.current_command
    end

    test "does nothing when no command running", %{session_id: session_id} do
      :ok = SessionServer.cancel(session_id)

      refute_receive {:jido_shell_session, _, _}, 100
    end

    test "allows new command after cancellation", %{session_id: session_id} do
      :ok = SessionServer.run_command(session_id, "sleep 10")
      assert_receive {:jido_shell_session, _, {:command_started, _}}

      :ok = SessionServer.cancel(session_id)
      assert_receive {:jido_shell_session, _, :command_cancelled}

      :ok = SessionServer.run_command(session_id, "echo done")
      assert_receive {:jido_shell_session, _, {:command_started, "echo done"}}
      assert_receive {:jido_shell_session, _, {:output, "done\n"}}
      assert_receive {:jido_shell_session, _, :command_done}
    end
  end

  describe "streaming" do
    test "streams output chunks", %{session_id: session_id} do
      :ok = SessionServer.run_command(session_id, "seq 3 10")

      assert_receive {:jido_shell_session, _, {:command_started, _}}
      assert_receive {:jido_shell_session, _, {:output, "1\n"}}
      assert_receive {:jido_shell_session, _, {:output, "2\n"}}
      assert_receive {:jido_shell_session, _, {:output, "3\n"}}
      assert_receive {:jido_shell_session, _, :command_done}
    end
  end

  describe "robustness" do
    test "handles late messages from cancelled command", %{session_id: session_id} do
      :ok = SessionServer.run_command(session_id, "seq 5 50")
      assert_receive {:jido_shell_session, _, {:command_started, _}}

      assert_receive {:jido_shell_session, _, {:output, "1\n"}}

      :ok = SessionServer.cancel(session_id)
      assert_receive {:jido_shell_session, _, :command_cancelled}

      Process.sleep(100)

      {:ok, state} = SessionServer.get_state(session_id)
      refute state.current_command
    end

    test "rejects command when busy", %{session_id: session_id} do
      :ok = SessionServer.run_command(session_id, "sleep 5")
      assert_receive {:jido_shell_session, _, {:command_started, _}}

      :ok = SessionServer.run_command(session_id, "echo hello")

      assert_receive {:jido_shell_session, _, {:error, %Jido.Shell.Error{code: {:shell, :busy}}}}

      :ok = SessionServer.cancel(session_id)
    end
  end
end
