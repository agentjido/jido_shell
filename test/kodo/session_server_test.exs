defmodule Kodo.SessionServerTest do
  use Kodo.Case, async: true

  alias Kodo.Session
  alias Kodo.SessionServer

  describe "start_link/1" do
    test "starts a session server" do
      session_id = Session.generate_id()
      {:ok, pid} = SessionServer.start_link(session_id: session_id, workspace_id: :test)
      assert Process.alive?(pid)
    end

    test "registers with SessionRegistry" do
      session_id = Session.generate_id()
      {:ok, _pid} = SessionServer.start_link(session_id: session_id, workspace_id: :test)
      assert {:ok, _pid} = Session.lookup(session_id)
    end
  end

  describe "get_state/1" do
    test "returns the session state" do
      session_id = Session.generate_id()
      {:ok, _} = SessionServer.start_link(session_id: session_id, workspace_id: :test_ws)

      {:ok, state} = SessionServer.get_state(session_id)

      assert state.id == session_id
      assert state.workspace_id == :test_ws
      assert state.cwd == "/"
    end

    test "respects initial options" do
      session_id = Session.generate_id()

      {:ok, _} =
        SessionServer.start_link(
          session_id: session_id,
          workspace_id: :test,
          cwd: "/home/user",
          env: %{"FOO" => "bar"}
        )

      {:ok, state} = SessionServer.get_state(session_id)

      assert state.cwd == "/home/user"
      assert state.env == %{"FOO" => "bar"}
    end
  end

  describe "subscribe/3 and unsubscribe/2" do
    test "subscribes transport to events" do
      session_id = Session.generate_id()
      {:ok, _} = SessionServer.start_link(session_id: session_id, workspace_id: :test)

      :ok = SessionServer.subscribe(session_id, self())

      {:ok, state} = SessionServer.get_state(session_id)
      assert MapSet.member?(state.transports, self())
    end

    test "unsubscribes transport" do
      session_id = Session.generate_id()
      {:ok, _} = SessionServer.start_link(session_id: session_id, workspace_id: :test)

      :ok = SessionServer.subscribe(session_id, self())
      :ok = SessionServer.unsubscribe(session_id, self())

      {:ok, state} = SessionServer.get_state(session_id)
      refute MapSet.member?(state.transports, self())
    end

    test "removes transport when it crashes" do
      session_id = Session.generate_id()
      {:ok, _} = SessionServer.start_link(session_id: session_id, workspace_id: :test)

      transport =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      :ok = SessionServer.subscribe(session_id, transport)

      {:ok, state} = SessionServer.get_state(session_id)
      assert MapSet.member?(state.transports, transport)

      Process.exit(transport, :kill)
      Process.sleep(10)

      {:ok, state} = SessionServer.get_state(session_id)
      refute MapSet.member?(state.transports, transport)
    end
  end

  describe "run_command/3" do
    test "adds command to history and broadcasts events" do
      session_id = Session.generate_id()
      {:ok, _} = SessionServer.start_link(session_id: session_id, workspace_id: :test)
      :ok = SessionServer.subscribe(session_id, self())

      :ok = SessionServer.run_command(session_id, "echo hello")

      assert_receive {:kodo_session, ^session_id, {:command_started, "echo hello"}}
      assert_receive {:kodo_session, ^session_id, {:output, "hello\n"}}
      assert_receive {:kodo_session, ^session_id, :command_done}

      {:ok, state} = SessionServer.get_state(session_id)
      assert "echo hello" in state.history
    end

    test "broadcasts error for unknown command" do
      session_id = Session.generate_id()
      {:ok, _} = SessionServer.start_link(session_id: session_id, workspace_id: :test)
      :ok = SessionServer.subscribe(session_id, self())

      :ok = SessionServer.run_command(session_id, "unknown_cmd")

      assert_receive {:kodo_session, ^session_id, {:command_started, "unknown_cmd"}}
      assert_receive {:kodo_session, ^session_id, {:error, %Kodo.Error{code: {:shell, :unknown_command}}}}
    end

    test "broadcasts busy error when command already running" do
      session_id = Session.generate_id()
      {:ok, server_pid} = SessionServer.start_link(session_id: session_id, workspace_id: :test)
      :ok = SessionServer.subscribe(session_id, self())

      :sys.suspend(server_pid)

      :ok = SessionServer.run_command(session_id, "echo first")
      :ok = SessionServer.run_command(session_id, "echo second")

      :sys.resume(server_pid)

      assert_receive {:kodo_session, ^session_id, {:command_started, "echo first"}}
      assert_receive {:kodo_session, ^session_id, {:error, %Kodo.Error{code: {:shell, :busy}}}}
    end

    test "executes pwd command with session cwd" do
      session_id = Session.generate_id()
      {:ok, _} = SessionServer.start_link(session_id: session_id, workspace_id: :test, cwd: "/home/user")
      :ok = SessionServer.subscribe(session_id, self())

      :ok = SessionServer.run_command(session_id, "pwd")

      assert_receive {:kodo_session, ^session_id, {:command_started, "pwd"}}
      assert_receive {:kodo_session, ^session_id, {:output, "/home/user\n"}}
      assert_receive {:kodo_session, ^session_id, :command_done}
    end

    test "clears current_command after completion" do
      session_id = Session.generate_id()
      {:ok, _} = SessionServer.start_link(session_id: session_id, workspace_id: :test)
      :ok = SessionServer.subscribe(session_id, self())

      :ok = SessionServer.run_command(session_id, "echo test")

      assert_receive {:kodo_session, ^session_id, :command_done}

      {:ok, state} = SessionServer.get_state(session_id)
      assert state.current_command == nil
    end
  end
end
