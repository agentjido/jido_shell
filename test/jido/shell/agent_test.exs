defmodule Jido.Shell.AgentTest do
  use Jido.Shell.Case, async: false

  import Mimic

  alias Jido.Shell.Agent
  alias Jido.Shell.VFS

  defp poll_until(fun, timeout \\ 100, interval \\ 5) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll(fun, deadline, interval)
  end

  defp do_poll(fun, deadline, interval) do
    case fun.() do
      {:ok, result} ->
        {:ok, result}

      :retry ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(interval)
          do_poll(fun, deadline, interval)
        else
          {:error, :timeout}
        end
    end
  end

  setup do
    VFS.init()
    workspace_id = "agent_test_#{System.unique_integer([:positive])}"
    fs_name = "agent_fs_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Jido.VFS.Adapter.InMemory, {Jido.VFS.Adapter.InMemory, %Jido.VFS.Adapter.InMemory.Config{name: fs_name}}}
    )

    :ok = VFS.mount(workspace_id, "/", Jido.VFS.Adapter.InMemory, name: fs_name)

    on_exit(fn ->
      VFS.unmount(workspace_id, "/")
    end)

    {:ok, workspace_id: workspace_id}
  end

  describe "new/2" do
    test "creates a new session", %{workspace_id: workspace_id} do
      {:ok, session_id} = Agent.new(workspace_id)

      assert String.starts_with?(session_id, "sess-")

      Agent.stop(session_id)
    end
  end

  describe "run/3" do
    setup %{workspace_id: workspace_id} do
      {:ok, session_id} = Agent.new(workspace_id)

      on_exit(fn ->
        Agent.stop(session_id)
      end)

      {:ok, session_id: session_id}
    end

    test "runs echo command", %{session_id: session_id} do
      {:ok, output} = Agent.run(session_id, "echo hello world")
      assert output == "hello world\n"
    end

    test "runs pwd command", %{session_id: session_id} do
      {:ok, output} = Agent.run(session_id, "pwd")
      assert output == "/\n"
    end

    test "returns error for unknown command", %{session_id: session_id} do
      {:error, error} = Agent.run(session_id, "unknowncmd")
      assert error.code == {:shell, :unknown_command}
    end

    test "runs commands with arguments", %{session_id: session_id} do
      {:ok, _} = Agent.run(session_id, "mkdir /testdir")
      {:ok, output} = Agent.run(session_id, "ls /")
      assert output =~ "testdir"
    end

    test "denies sandbox network by default", %{session_id: session_id} do
      {:error, error} = Agent.run(session_id, "bash -c \"curl https://example.com\"")
      assert error.code == {:shell, :network_blocked}
    end

    test "allows per-execution network context overrides", %{session_id: session_id} do
      {:error, error} =
        Agent.run(
          session_id,
          "bash -c \"curl https://example.com\"",
          execution_context: %{network: %{allow_domains: ["example.com"]}}
        )

      assert error.code == {:shell, :unknown_command}
    end

    test "returns typed errors when session cannot be subscribed" do
      assert {:error, %Jido.Shell.Error{code: {:session, :not_found}}} =
               Agent.run("missing-session", "echo hi")
    end

    test "returns cancellation errors when session command is cancelled", %{session_id: session_id} do
      {:ok, :subscribed} = Jido.Shell.ShellSessionServer.subscribe(session_id, self())

      task =
        Task.async(fn ->
          Agent.run(session_id, "sleep 5", timeout: 10_000)
        end)

      assert_receive {:jido_shell_session, ^session_id, {:command_started, "sleep 5"}}
      assert {:ok, :cancelled} = Jido.Shell.ShellSessionServer.cancel(session_id)

      assert {:error, %Jido.Shell.Error{code: {:command, :cancelled}}} = Task.await(task, 2_000)
    end

    test "returns crash errors when a command crashes", %{session_id: session_id} do
      {:ok, :subscribed} = Jido.Shell.ShellSessionServer.subscribe(session_id, self())

      task =
        Task.async(fn ->
          Agent.run(session_id, "sleep 1", timeout: 10_000)
        end)

      assert_receive {:jido_shell_session, ^session_id, {:command_started, "sleep 1"}}

      send(task.pid, {:jido_shell_session, session_id, {:command_crashed, :boom}})

      assert {:error, %Jido.Shell.Error{code: {:command, :crashed}}} = Task.await(task, 2_000)
    end

    test "returns timeout errors when no completion event is received in time", %{session_id: session_id} do
      assert {:error, %Jido.Shell.Error{code: {:command, :timeout}}} =
               Agent.run(session_id, "sleep 1", timeout: 10)
    end
  end

  describe "file operations" do
    setup %{workspace_id: workspace_id} do
      {:ok, session_id} = Agent.new(workspace_id)

      on_exit(fn ->
        Agent.stop(session_id)
      end)

      {:ok, session_id: session_id}
    end

    test "write and read file", %{session_id: session_id} do
      :ok = Agent.write_file(session_id, "/test.txt", "Hello Agent!")
      {:ok, content} = Agent.read_file(session_id, "/test.txt")
      assert content == "Hello Agent!"
    end

    test "read file with relative path", %{session_id: session_id} do
      :ok = Agent.write_file(session_id, "/test.txt", "content")
      {:ok, content} = Agent.read_file(session_id, "test.txt")
      assert content == "content"
    end

    test "list_dir", %{session_id: session_id} do
      :ok = Agent.write_file(session_id, "/file1.txt", "a")
      :ok = Agent.write_file(session_id, "/file2.txt", "b")

      {:ok, entries} = Agent.list_dir(session_id, "/")
      names = Enum.map(entries, & &1.name)

      assert "file1.txt" in names
      assert "file2.txt" in names
    end

    test "list_dir with default path", %{session_id: session_id} do
      :ok = Agent.write_file(session_id, "/file.txt", "a")

      {:ok, entries} = Agent.list_dir(session_id)
      names = Enum.map(entries, & &1.name)

      assert "file.txt" in names
    end

    test "read non-existent file returns error", %{session_id: session_id} do
      {:error, error} = Agent.read_file(session_id, "/missing.txt")
      assert error.code == {:vfs, :not_found}
    end
  end

  describe "run_all/3" do
    setup %{workspace_id: workspace_id} do
      {:ok, session_id} = Agent.new(workspace_id)

      on_exit(fn ->
        Agent.stop(session_id)
      end)

      {:ok, session_id: session_id}
    end

    test "runs multiple commands", %{session_id: session_id} do
      results = Agent.run_all(session_id, ["echo one", "echo two", "pwd"])

      assert [
               {"echo one", {:ok, "one\n"}},
               {"echo two", {:ok, "two\n"}},
               {"pwd", {:ok, "/\n"}}
             ] = results
    end

    test "handles errors in sequence", %{session_id: session_id} do
      results = Agent.run_all(session_id, ["echo ok", "unknowncmd", "echo after"])

      assert [
               {"echo ok", {:ok, "ok\n"}},
               {"unknowncmd", {:error, _}},
               {"echo after", {:ok, "after\n"}}
             ] = results
    end
  end

  describe "state/1 and cwd/1" do
    setup %{workspace_id: workspace_id} do
      {:ok, session_id} = Agent.new(workspace_id)

      on_exit(fn ->
        Agent.stop(session_id)
      end)

      {:ok, session_id: session_id}
    end

    test "returns session state", %{session_id: session_id} do
      {:ok, state} = Agent.state(session_id)
      assert state.cwd == "/"
    end

    test "cwd returns current directory", %{session_id: session_id} do
      assert {:ok, "/"} = Agent.cwd(session_id)
    end

    test "cwd changes after cd command", %{session_id: session_id} do
      {:ok, _} = Agent.run(session_id, "mkdir /testdir")
      {:ok, _} = Agent.run(session_id, "cd /testdir")
      assert {:ok, "/testdir"} = Agent.cwd(session_id)
    end
  end

  describe "stop/1" do
    test "stops the session", %{workspace_id: workspace_id} do
      {:ok, session_id} = Agent.new(workspace_id)
      {:ok, pid} = Jido.Shell.ShellSession.lookup(session_id)
      ref = Process.monitor(pid)

      :ok = Agent.stop(session_id)

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      {:ok, :done} =
        poll_until(fn ->
          case Jido.Shell.ShellSession.lookup(session_id) do
            {:error, :not_found} -> {:ok, :done}
            {:ok, _} -> :retry
          end
        end)
    end

    test "returns error for non-existent session" do
      assert {:error, :not_found} = Agent.stop("nonexistent-session-id")
    end
  end

  describe "command integration" do
    setup %{workspace_id: workspace_id} do
      {:ok, session_id} = Agent.new(workspace_id)

      on_exit(fn ->
        Agent.stop(session_id)
      end)

      {:ok, session_id: session_id}
    end

    test "env command through agent", %{session_id: session_id} do
      {:ok, output} = Agent.run(session_id, "env FOO=bar")
      assert output == ""

      {:ok, output} = Agent.run(session_id, "env FOO")
      assert output == "FOO=bar\n"
    end

    test "cp command through agent", %{session_id: session_id} do
      :ok = Agent.write_file(session_id, "/source.txt", "copy me")
      {:ok, _} = Agent.run(session_id, "cp /source.txt /dest.txt")
      {:ok, content} = Agent.read_file(session_id, "/dest.txt")
      assert content == "copy me"
    end

    test "rm command through agent", %{session_id: session_id} do
      :ok = Agent.write_file(session_id, "/delete_me.txt", "delete")
      {:ok, _} = Agent.run(session_id, "rm /delete_me.txt")
      {:error, error} = Agent.read_file(session_id, "/delete_me.txt")
      assert error.code == {:vfs, :not_found}
    end
  end

  describe "run/3 mailbox ordering" do
    setup :set_mimic_global
    setup :verify_on_exit!

    test "ignores pre-start session events until command_started arrives" do
      session_id = "mock_session_#{System.unique_integer([:positive])}"
      copy(Jido.Shell.ShellSessionServer)

      expect(Jido.Shell.ShellSessionServer, :subscribe, fn ^session_id, pid when pid == self() ->
        {:ok, :subscribed}
      end)

      expect(Jido.Shell.ShellSessionServer, :run_command, fn ^session_id, "echo hi", [] ->
        send(self(), {:jido_shell_session, session_id, {:output, "stale\n"}})
        send(self(), {:jido_shell_session, session_id, {:command_started, "echo hi"}})
        send(self(), {:jido_shell_session, session_id, :command_done})
        {:ok, :accepted}
      end)

      expect(Jido.Shell.ShellSessionServer, :unsubscribe, fn ^session_id, pid when pid == self() ->
        {:ok, :unsubscribed}
      end)

      assert {:ok, ""} = Agent.run(session_id, "echo hi")
    end
  end
end
