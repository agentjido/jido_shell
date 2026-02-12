defmodule Jido.Shell.SessionTest do
  use Jido.Shell.Case, async: true

  alias Jido.Shell.Session

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

  describe "generate_id/0" do
    test "generates unique IDs with sess- prefix" do
      id = Session.generate_id()
      assert String.starts_with?(id, "sess-")
    end

    test "generates different IDs each time" do
      id1 = Session.generate_id()
      id2 = Session.generate_id()
      assert id1 != id2
    end

    test "ID has expected format (sess- followed by UUID)" do
      id = Session.generate_id()

      assert Regex.match?(
               ~r/^sess-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
               id
             )
    end
  end

  describe "via_registry/1" do
    test "returns via tuple with correct structure" do
      via = Session.via_registry("sess-123")
      assert {:via, Registry, {Jido.Shell.SessionRegistry, "sess-123"}} = via
    end
  end

  describe "lookup/1" do
    test "returns {:error, :not_found} for non-existent session" do
      assert {:error, :not_found} = Session.lookup("nonexistent-session")
    end

    test "returns {:ok, pid} when session is registered" do
      session_id = Session.generate_id()
      {:ok, _pid} = Registry.register(Jido.Shell.SessionRegistry, session_id, nil)

      assert {:ok, pid} = Session.lookup(session_id)
      assert is_pid(pid)
      assert pid == self()
    end
  end

  describe "start/2" do
    test "starts a session for a workspace" do
      {:ok, session_id} = Session.start(:test_workspace)
      assert String.starts_with?(session_id, "sess-")

      assert {:ok, pid} = Session.lookup(session_id)
      assert Process.alive?(pid)
    end

    test "accepts custom session_id" do
      custom_id = "sess-custom-123"
      {:ok, ^custom_id} = Session.start(:test, session_id: custom_id)
      assert {:ok, _} = Session.lookup(custom_id)
    end

    test "passes options to SessionServer" do
      {:ok, session_id} = Session.start(:test, cwd: "/home", env: %{"X" => "1"})
      {:ok, state} = Jido.Shell.SessionServer.get_state(session_id)
      assert state.cwd == "/home"
      assert state.env == %{"X" => "1"}
    end
  end

  describe "stop/1" do
    test "stops a running session" do
      {:ok, session_id} = Session.start(:test)
      assert {:ok, pid} = Session.lookup(session_id)
      ref = Process.monitor(pid)

      :ok = Session.stop(session_id)

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      {:ok, :done} =
        poll_until(fn ->
          case Session.lookup(session_id) do
            {:error, :not_found} -> {:ok, :done}
            {:ok, _} -> :retry
          end
        end)
    end

    test "returns error for non-existent session" do
      assert {:error, :not_found} = Session.stop("nonexistent")
    end
  end

  describe "start_with_vfs/2" do
    setup do
      Jido.Shell.VFS.init()
      :ok
    end

    test "starts a session with VFS auto-mounted" do
      workspace_id = :"test_ws_vfs_#{System.unique_integer([:positive])}"

      {:ok, session_id} = Session.start_with_vfs(workspace_id)

      assert String.starts_with?(session_id, "sess-")
      assert {:ok, _} = Session.lookup(session_id)

      mounts = Jido.Shell.VFS.list_mounts(workspace_id)
      assert length(mounts) == 1
      assert hd(mounts).path == "/"

      on_exit(fn ->
        Jido.Shell.VFS.unmount(workspace_id, "/")
      end)
    end

    test "does not re-mount if VFS already mounted" do
      workspace_id = :"test_ws_vfs_exists_#{System.unique_integer([:positive])}"
      fs_name = :"test_fs_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Jido.VFS.Adapter.InMemory, {Jido.VFS.Adapter.InMemory, %Jido.VFS.Adapter.InMemory.Config{name: fs_name}}}
      )

      :ok = Jido.Shell.VFS.mount(workspace_id, "/", Jido.VFS.Adapter.InMemory, name: fs_name)

      {:ok, session_id} = Session.start_with_vfs(workspace_id)

      assert {:ok, _} = Session.lookup(session_id)
      mounts = Jido.Shell.VFS.list_mounts(workspace_id)
      assert length(mounts) == 1

      on_exit(fn ->
        Jido.Shell.VFS.unmount(workspace_id, "/")
      end)
    end
  end
end
