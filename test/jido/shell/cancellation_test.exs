defmodule Jido.Shell.CancellationTest do
  use Jido.Shell.Case, async: true

  alias Jido.Shell.ShellSession
  alias Jido.Shell.ShellSessionServer
  @event_timeout 1_000

  setup do
    workspace_id = "test_ws_#{System.unique_integer([:positive])}"
    {:ok, session_id} = ShellSession.start(workspace_id)
    {:ok, :subscribed} = ShellSessionServer.subscribe(session_id, self())

    {:ok, session_id: session_id}
  end

  describe "cancel/1" do
    test "cancels running command", %{session_id: session_id} do
      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "sleep 10")

      assert_receive {:jido_shell_session, _, {:command_started, "sleep 10"}}, @event_timeout
      assert_receive {:jido_shell_session, _, {:output, "Sleeping for 10 seconds...\n"}}, @event_timeout

      {:ok, :cancelled} = ShellSessionServer.cancel(session_id)

      assert_receive {:jido_shell_session, _, :command_cancelled}, @event_timeout

      {:ok, state} = ShellSessionServer.get_state(session_id)
      refute state.current_command
    end

    test "does nothing when no command running", %{session_id: session_id} do
      assert {:error, %Jido.Shell.Error{code: {:session, :invalid_state_transition}}} =
               ShellSessionServer.cancel(session_id)

      refute_receive {:jido_shell_session, _, _}, 100
    end

    test "allows new command after cancellation", %{session_id: session_id} do
      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "sleep 10")
      assert_receive {:jido_shell_session, _, {:command_started, _}}, @event_timeout

      {:ok, :cancelled} = ShellSessionServer.cancel(session_id)
      assert_receive {:jido_shell_session, _, :command_cancelled}, @event_timeout

      wait_until_idle(session_id)

      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "echo done")
      assert_receive {:jido_shell_session, _, {:command_started, "echo done"}}, @event_timeout
      assert_receive {:jido_shell_session, _, {:output, "done\n"}}, @event_timeout
      assert_receive {:jido_shell_session, _, :command_done}, @event_timeout
    end
  end

  describe "streaming" do
    test "streams output chunks", %{session_id: session_id} do
      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "seq 3 10")

      assert_receive {:jido_shell_session, _, {:command_started, _}}, @event_timeout
      assert_receive {:jido_shell_session, _, {:output, "1\n"}}, @event_timeout
      assert_receive {:jido_shell_session, _, {:output, "2\n"}}, @event_timeout
      assert_receive {:jido_shell_session, _, {:output, "3\n"}}, @event_timeout
      assert_receive {:jido_shell_session, _, :command_done}, @event_timeout
    end
  end

  describe "robustness" do
    test "handles late messages from cancelled command", %{session_id: session_id} do
      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "seq 5 50")
      assert_receive {:jido_shell_session, _, {:command_started, _}}, @event_timeout

      assert_receive {:jido_shell_session, _, {:output, "1\n"}}, @event_timeout

      {:ok, :cancelled} = ShellSessionServer.cancel(session_id)
      assert_receive {:jido_shell_session, _, :command_cancelled}, @event_timeout

      Process.sleep(100)

      {:ok, state} = ShellSessionServer.get_state(session_id)
      refute state.current_command
    end

    test "rejects command when busy", %{session_id: session_id} do
      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "sleep 5")
      assert_receive {:jido_shell_session, _, {:command_started, _}}, @event_timeout

      assert {:error, %Jido.Shell.Error{code: {:shell, :busy}}} =
               ShellSessionServer.run_command(session_id, "echo hello")

      assert_receive {:jido_shell_session, _, {:error, %Jido.Shell.Error{code: {:shell, :busy}}}}, @event_timeout

      {:ok, :cancelled} = ShellSessionServer.cancel(session_id)
    end
  end

  defp wait_until_idle(session_id, attempts \\ 100)
  defp wait_until_idle(_session_id, 0), do: :ok

  defp wait_until_idle(session_id, attempts) do
    case ShellSessionServer.get_state(session_id) do
      {:ok, %{current_command: nil}} ->
        :ok

      _ ->
        Process.sleep(10)
        wait_until_idle(session_id, attempts - 1)
    end
  end
end
