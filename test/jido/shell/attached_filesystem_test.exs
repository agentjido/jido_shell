defmodule Jido.Shell.AttachedFilesystemTest do
  use ExUnit.Case, async: false
  alias Jido.Shell.{Agent, ShellSession, ShellSessionServer, VFS}

  setup do
    fs = Jido.VFS.Adapter.InMemory.configure(name: make_ref())
    storage = start_supervised!({Jido.VFS.Adapter.InMemory, fs})
    %{fs: fs, storage: storage}
  end

  test "two sessions share caller storage but own separate command state", %{fs: fs, storage: storage} do
    {:ok, a} = Agent.new(fs)
    {:ok, b} = Agent.new(fs)

    try do
      assert :ok = Agent.write_file(a, "/file", "value")
      assert {:ok, "value"} = Agent.read_file(b, "/file")
      assert {:ok, "value"} = Jido.VFS.read(fs, "file")
      :ok = Jido.VFS.write(fs, "file", "direct")
      assert {:ok, "direct"} = Agent.run(a, "cat /file")
      assert :ok = Agent.stop(a)
      assert Process.alive?(storage)
      assert {:ok, "direct"} = Agent.read_file(b, "/file")
    after
      ShellSession.stop(a)
      ShellSession.stop(b)
    end
  end

  test "stop waits for a running local command to exit", %{fs: fs, storage: storage} do
    {:ok, session} = Agent.new(fs)
    {:ok, :accepted} = ShellSessionServer.run_command(session, "sleep 30; write /late bad")
    {:ok, state} = ShellSessionServer.get_state(session)
    task = state.current_command.task
    assert Process.alive?(task)
    assert :ok = ShellSession.stop(session)
    refute Process.alive?(task)
    assert Process.alive?(storage)
    assert {:ok, :missing} = Jido.VFS.file_exists(fs, "late")
    assert VFS.list_mounts(state.workspace_id) == []
  end

  test "failed session startup releases only routing state", %{fs: fs, storage: storage} do
    before = :ets.tab2list(:jido_shell_vfs_mounts) |> Enum.sort()
    assert {:error, _} = ShellSession.start_with_filesystem(fs, backend: {NotABackend, %{}})
    assert :ets.tab2list(:jido_shell_vfs_mounts) |> Enum.sort() == before
    assert Process.alive?(storage)
  end

  test "owner exit does not restart the session or stop unrelated sessions", %{fs: fs, storage: storage} do
    parent = self()
    {:ok, other} = Agent.new(fs)
    {:ok, other_pid} = ShellSession.lookup(other)
    supervisor = Process.whereis(Jido.Shell.SessionSupervisor)

    owner =
      spawn(fn ->
        {:ok, session} = ShellSession.start_with_filesystem(fs, owner: self())
        send(parent, {:session, session})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:session, session}
    {:ok, pid} = ShellSession.lookup(session)
    ref = Process.monitor(pid)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    # A supervisor call is a barrier after it handles the child exit.
    children = DynamicSupervisor.which_children(supervisor)
    refute Enum.any?(children, fn {_, child, _, _} -> child == pid end)
    assert ShellSession.lookup(session) == {:error, :not_found}
    assert Process.alive?(other_pid)
    assert Process.alive?(storage)
    assert :ok = ShellSession.stop(other)
  end

  test "invalid metadata does not attach storage", %{fs: fs} do
    before = :ets.tab2list(:jido_shell_vfs_mounts) |> Enum.sort()
    assert {:error, _} = ShellSession.start_with_filesystem(fs, meta: nil)
    assert :ets.tab2list(:jido_shell_vfs_mounts) |> Enum.sort() == before
  end

  test "a retired namespace monitor cannot remove a new mount", %{fs: fs} do
    id = "reuse-#{System.unique_integer([:positive])}"
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    :ok = VFS.MountTable.attach(id, "/", fs)
    :ok = VFS.MountTable.track(id, owner)
    :ok = VFS.unmount(id, "/")
    :ok = VFS.MountTable.attach(id, "/", fs)
    send(owner, :stop)
    # The old monitor is removed before the namespace can be reused.
    state = :sys.get_state(VFS.MountTable)
    refute Enum.any?(state, fn {_, tracked} -> tracked == id end)
    assert [_] = VFS.list_mounts(id)
    :ok = VFS.unmount_workspace(id)
  end

  test "a stopped session PID cannot select a replacement session", %{fs: fs} do
    id = "reuse-session-#{System.unique_integer([:positive])}"
    {:ok, ^id} = ShellSession.start_with_filesystem(fs, session_id: id)
    {:ok, old} = ShellSession.lookup(id)
    :ok = ShellSession.stop(old)
    {:ok, ^id} = ShellSession.start_with_filesystem(fs, session_id: id)
    {:ok, fresh} = ShellSession.lookup(id)
    assert {:error, _} = Agent.run(old, "write /wrong bad")
    assert {:error, :not_found} = ShellSession.stop(old)
    assert Process.alive?(fresh)
    assert {:ok, "yes\n"} = Agent.run(fresh, "echo yes")
    :ok = ShellSession.stop(fresh)
  end

  test "lookup rejects a dead session before registry cleanup" do
    parent = self()
    id = ShellSession.generate_id()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(Jido.Shell.SessionRegistry, id, nil)
        send(parent, {:registered, self()})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:registered, ^pid}
    partitions = for {_, partition, _, _} <- Supervisor.which_children(Jido.Shell.SessionRegistry), do: partition
    for partition <- partitions, do: :sys.suspend(partition)

    try do
      assert {:ok, ^pid} = ShellSession.lookup(id)
      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert [{^pid, nil}] = Registry.lookup(Jido.Shell.SessionRegistry, id)
      assert {:error, :not_found} = ShellSession.lookup(id)
    after
      for partition <- partitions, do: :sys.resume(partition)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end
  end
end
