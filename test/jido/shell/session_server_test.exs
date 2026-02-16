defmodule Jido.Shell.ShellSessionServerTest do
  use Jido.Shell.Case, async: true

  alias Jido.Shell.ShellSession
  alias Jido.Shell.ShellSessionServer

  describe "start_link/1" do
    test "starts a session server" do
      session_id = ShellSession.generate_id()
      {:ok, pid} = ShellSessionServer.start_link(session_id: session_id, workspace_id: "test")
      assert Process.alive?(pid)
    end

    test "registers with SessionRegistry" do
      session_id = ShellSession.generate_id()
      {:ok, _pid} = ShellSessionServer.start_link(session_id: session_id, workspace_id: "test")
      assert {:ok, _pid} = ShellSession.lookup(session_id)
    end

    test "accepts explicit backend configuration" do
      session_id = ShellSession.generate_id()

      {:ok, _pid} =
        ShellSessionServer.start_link(
          session_id: session_id,
          workspace_id: "test",
          backend: {Jido.Shell.Backend.Local, %{}}
        )

      {:ok, state} = ShellSessionServer.get_state(session_id)
      assert state.backend == Jido.Shell.Backend.Local
    end
  end

  describe "get_state/1" do
    test "returns the session state" do
      session_id = ShellSession.generate_id()
      {:ok, _} = ShellSessionServer.start_link(session_id: session_id, workspace_id: "test_ws")

      {:ok, state} = ShellSessionServer.get_state(session_id)

      assert state.id == session_id
      assert state.workspace_id == "test_ws"
      assert state.cwd == "/"
    end

    test "respects initial options" do
      session_id = ShellSession.generate_id()

      {:ok, _} =
        ShellSessionServer.start_link(
          session_id: session_id,
          workspace_id: "test",
          cwd: "/home/user",
          env: %{"FOO" => "bar"}
        )

      {:ok, state} = ShellSessionServer.get_state(session_id)

      assert state.cwd == "/home/user"
      assert state.env == %{"FOO" => "bar"}
    end

    test "returns canonical state identity" do
      session_id = ShellSession.generate_id()
      {:ok, _} = ShellSessionServer.start_link(session_id: session_id, workspace_id: "test_ws")

      assert {:ok, %Jido.Shell.ShellSession.State{} = state} = ShellSessionServer.get_state(session_id)
      assert state.__struct__ == Jido.Shell.ShellSession.State
    end
  end

  describe "subscribe/3 and unsubscribe/2" do
    test "subscribes transport to events" do
      session_id = ShellSession.generate_id()
      {:ok, _} = ShellSessionServer.start_link(session_id: session_id, workspace_id: "test")

      {:ok, :subscribed} = ShellSessionServer.subscribe(session_id, self())

      {:ok, state} = ShellSessionServer.get_state(session_id)
      assert MapSet.member?(state.transports, self())
    end

    test "unsubscribes transport" do
      session_id = ShellSession.generate_id()
      {:ok, _} = ShellSessionServer.start_link(session_id: session_id, workspace_id: "test")

      {:ok, :subscribed} = ShellSessionServer.subscribe(session_id, self())
      {:ok, :unsubscribed} = ShellSessionServer.unsubscribe(session_id, self())

      {:ok, state} = ShellSessionServer.get_state(session_id)
      refute MapSet.member?(state.transports, self())
    end

    test "removes transport when it crashes" do
      session_id = ShellSession.generate_id()
      {:ok, _} = ShellSessionServer.start_link(session_id: session_id, workspace_id: "test")

      transport =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, :subscribed} = ShellSessionServer.subscribe(session_id, transport)

      {:ok, state} = ShellSessionServer.get_state(session_id)
      assert MapSet.member?(state.transports, transport)

      Process.exit(transport, :kill)
      Process.sleep(10)

      {:ok, state} = ShellSessionServer.get_state(session_id)
      refute MapSet.member?(state.transports, transport)
    end
  end

  describe "run_command/3" do
    test "adds command to history and broadcasts events" do
      session_id = ShellSession.generate_id()
      {:ok, _} = ShellSessionServer.start_link(session_id: session_id, workspace_id: "test")
      {:ok, :subscribed} = ShellSessionServer.subscribe(session_id, self())

      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "echo hello")

      assert_receive {:jido_shell_session, ^session_id, {:command_started, "echo hello"}}
      assert_receive {:jido_shell_session, ^session_id, {:output, "hello\n"}}
      assert_receive {:jido_shell_session, ^session_id, :command_done}

      {:ok, state} = ShellSessionServer.get_state(session_id)
      assert "echo hello" in state.history
    end

    test "broadcasts error for unknown command" do
      session_id = ShellSession.generate_id()
      {:ok, _} = ShellSessionServer.start_link(session_id: session_id, workspace_id: "test")
      {:ok, :subscribed} = ShellSessionServer.subscribe(session_id, self())

      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "unknown_cmd")

      assert_receive {:jido_shell_session, ^session_id, {:command_started, "unknown_cmd"}}
      assert_receive {:jido_shell_session, ^session_id, {:error, %Jido.Shell.Error{code: {:shell, :unknown_command}}}}
    end

    test "broadcasts busy error when command already running" do
      session_id = ShellSession.generate_id()
      {:ok, _server_pid} = ShellSessionServer.start_link(session_id: session_id, workspace_id: "test")
      {:ok, :subscribed} = ShellSessionServer.subscribe(session_id, self())

      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "sleep 5")
      assert_receive {:jido_shell_session, ^session_id, {:command_started, "sleep 5"}}

      assert {:error, %Jido.Shell.Error{code: {:shell, :busy}}} =
               ShellSessionServer.run_command(session_id, "echo second")

      assert_receive {:jido_shell_session, ^session_id, {:error, %Jido.Shell.Error{code: {:shell, :busy}}}}

      {:ok, :cancelled} = ShellSessionServer.cancel(session_id)
    end

    test "executes pwd command with session cwd" do
      session_id = ShellSession.generate_id()
      {:ok, _} = ShellSessionServer.start_link(session_id: session_id, workspace_id: "test", cwd: "/home/user")
      {:ok, :subscribed} = ShellSessionServer.subscribe(session_id, self())

      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "pwd")

      assert_receive {:jido_shell_session, ^session_id, {:command_started, "pwd"}}
      assert_receive {:jido_shell_session, ^session_id, {:output, "/home/user\n"}}
      assert_receive {:jido_shell_session, ^session_id, :command_done}
    end

    test "clears current_command after completion" do
      session_id = ShellSession.generate_id()
      {:ok, _} = ShellSessionServer.start_link(session_id: session_id, workspace_id: "test")
      {:ok, :subscribed} = ShellSessionServer.subscribe(session_id, self())

      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "echo test")

      assert_receive {:jido_shell_session, ^session_id, :command_done}

      {:ok, state} = ShellSessionServer.get_state(session_id)
      assert state.current_command == nil
    end

    test "handles cast-based command execution and cancellation paths" do
      session_id = ShellSession.generate_id()
      {:ok, _} = ShellSessionServer.start_link(session_id: session_id, workspace_id: "test")
      {:ok, :subscribed} = ShellSessionServer.subscribe(session_id, self())
      {:ok, server_pid} = ShellSession.lookup(session_id)

      GenServer.cast(server_pid, {:run_command, "echo cast", []})
      assert_receive {:jido_shell_session, ^session_id, {:command_started, "echo cast"}}
      assert_receive {:jido_shell_session, ^session_id, {:output, "cast\n"}}
      assert_receive {:jido_shell_session, ^session_id, :command_done}

      # Idle cancel cast should be a no-op with explicit invalid transition handling internally.
      GenServer.cast(server_pid, :cancel)
      {:ok, state} = ShellSessionServer.get_state(session_id)
      assert state.current_command == nil
    end

    test "broadcasts command_crashed when monitored command exits unexpectedly" do
      session_id = ShellSession.generate_id()
      {:ok, _} = ShellSessionServer.start_link(session_id: session_id, workspace_id: "test")
      {:ok, :subscribed} = ShellSessionServer.subscribe(session_id, self())
      {:ok, server_pid} = ShellSession.lookup(session_id)

      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "sleep 1")
      assert_receive {:jido_shell_session, ^session_id, {:command_started, "sleep 1"}}
      {:ok, state} = ShellSessionServer.get_state(session_id)
      assert %{ref: ref, task: task_pid} = state.current_command

      send(server_pid, {:DOWN, ref, :process, task_pid, :boom})
      assert_receive {:jido_shell_session, ^session_id, {:command_crashed, :boom}}
    end

    test "ignores late command events and late finished messages after cancellation" do
      session_id = ShellSession.generate_id()
      {:ok, _} = ShellSessionServer.start_link(session_id: session_id, workspace_id: "test")
      {:ok, server_pid} = ShellSession.lookup(session_id)

      send(server_pid, {:command_event, {:output, "late"}})
      send(server_pid, {:command_finished, {:ok, nil}})

      {:ok, state} = ShellSessionServer.get_state(session_id)
      assert state.current_command == nil
    end
  end

  describe "missing session handling" do
    test "returns typed errors instead of exiting for missing sessions" do
      missing = "missing-session"

      assert {:error, %Jido.Shell.Error{code: {:session, :not_found}}} =
               ShellSessionServer.subscribe(missing, self())

      assert {:error, %Jido.Shell.Error{code: {:session, :not_found}}} =
               ShellSessionServer.unsubscribe(missing, self())

      assert {:error, %Jido.Shell.Error{code: {:session, :not_found}}} =
               ShellSessionServer.get_state(missing)

      assert {:error, %Jido.Shell.Error{code: {:session, :not_found}}} =
               ShellSessionServer.run_command(missing, "echo hi")

      assert {:error, %Jido.Shell.Error{code: {:session, :not_found}}} =
               ShellSessionServer.cancel(missing)
    end

    test "returns invalid session ID errors for malformed identifiers" do
      assert {:error, %Jido.Shell.Error{code: {:session, :invalid_session_id}}} =
               ShellSessionServer.get_state(nil)
    end

    test "handles registry entries that are not live session servers" do
      session_id = "fake-#{System.unique_integer([:positive])}"
      parent = self()

      pid =
        spawn(fn ->
          {:ok, _} = Registry.register(Jido.Shell.SessionRegistry, session_id, nil)
          send(parent, :registered)

          receive do
            {:"$gen_call", _from, _msg} -> exit(:not_a_server)
          end
        end)

      assert_receive :registered
      assert Process.alive?(pid)

      assert {:error, %Jido.Shell.Error{code: {:session, :not_found}}} =
               ShellSessionServer.get_state(session_id)
    end
  end
end
