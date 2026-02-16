defmodule Jido.Shell.VFSTest do
  use Jido.Shell.Case, async: false

  alias Jido.Shell.VFS

  defmodule BrokenAdapter do
    def starts_processes, do: true
    def configure(opts), do: {__MODULE__, %{name: Keyword.get(opts, :name, "broken")}}
  end

  setup do
    VFS.init()
    workspace_id = "test_ws_#{System.unique_integer([:positive])}"
    fs_name = "test_fs_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Jido.VFS.Adapter.InMemory, {Jido.VFS.Adapter.InMemory, %Jido.VFS.Adapter.InMemory.Config{name: fs_name}}}
    )

    :ok = VFS.mount(workspace_id, "/", Jido.VFS.Adapter.InMemory, name: fs_name)

    on_exit(fn ->
      VFS.unmount(workspace_id, "/")
    end)

    {:ok, workspace_id: workspace_id, fs_name: fs_name}
  end

  describe "init/0" do
    test "initializes the mount table" do
      assert :ok = VFS.init()
    end
  end

  describe "mount/4 and unmount/2" do
    test "mounts and lists mounts", %{workspace_id: workspace_id} do
      mounts = VFS.list_mounts(workspace_id)
      assert length(mounts) == 1
      assert hd(mounts).path == "/"
    end

    test "unmounts successfully", %{workspace_id: workspace_id} do
      assert :ok = VFS.unmount(workspace_id, "/")
      assert [] = VFS.list_mounts(workspace_id)
    end

    test "returns explicit errors for invalid workspace identifiers" do
      assert {:error, %Jido.Shell.Error{code: {:session, :invalid_workspace_id}}} =
               VFS.mount(:bad_workspace, "/", Jido.VFS.Adapter.InMemory, name: "bad")
    end

    test "returns already_exists when mount path is already taken", %{workspace_id: workspace_id} do
      assert {:error, %Jido.Shell.Error{code: {:vfs, :already_exists}}} =
               VFS.mount(workspace_id, "/", Jido.VFS.Adapter.InMemory, name: "dup")
    end

    test "returns mount_failed when adapter startup fails", %{workspace_id: workspace_id} do
      assert {:error, %Jido.Shell.Error{code: {:vfs, :mount_failed}}} =
               VFS.mount(workspace_id, "/broken", BrokenAdapter, name: "broken")
    end

    test "returns not_found when unmounting a missing path", %{workspace_id: workspace_id} do
      assert {:error, %Jido.Shell.Error{code: {:vfs, :not_found}}} =
               VFS.unmount(workspace_id, "/missing")
    end
  end

  describe "write_file/3 and read_file/2" do
    test "writes and reads a file", %{workspace_id: workspace_id} do
      assert :ok = VFS.write_file(workspace_id, "/hello.txt", "Hello, World!")
      assert {:ok, "Hello, World!"} = VFS.read_file(workspace_id, "/hello.txt")
    end

    test "returns error for non-existent file", %{workspace_id: workspace_id} do
      assert {:error, error} = VFS.read_file(workspace_id, "/missing.txt")
      assert error.code == {:vfs, :not_found}
    end

    test "overwrites existing file", %{workspace_id: workspace_id} do
      assert :ok = VFS.write_file(workspace_id, "/test.txt", "first")
      assert :ok = VFS.write_file(workspace_id, "/test.txt", "second")
      assert {:ok, "second"} = VFS.read_file(workspace_id, "/test.txt")
    end

    test "returns error when no mount exists" do
      unknown_ws = "unknown_ws_#{System.unique_integer([:positive])}"
      assert {:error, error} = VFS.read_file(unknown_ws, "/test.txt")
      assert error.code == {:vfs, :no_mount}
    end
  end

  describe "delete/2" do
    test "deletes a file", %{workspace_id: workspace_id} do
      VFS.write_file(workspace_id, "/delete-me.txt", "content")
      assert :ok = VFS.delete(workspace_id, "/delete-me.txt")
      assert {:error, _} = VFS.read_file(workspace_id, "/delete-me.txt")
    end
  end

  describe "list_dir/2" do
    test "lists directory contents", %{workspace_id: workspace_id} do
      VFS.write_file(workspace_id, "/file1.txt", "a")
      VFS.write_file(workspace_id, "/file2.txt", "b")

      {:ok, entries} = VFS.list_dir(workspace_id, "/")
      names = Enum.map(entries, & &1.name) |> Enum.sort()
      assert "file1.txt" in names
      assert "file2.txt" in names
    end

    test "returns empty list for empty directory", %{workspace_id: workspace_id} do
      VFS.mkdir(workspace_id, "/empty")
      {:ok, entries} = VFS.list_dir(workspace_id, "/empty")
      assert entries == []
    end
  end

  describe "stat/2" do
    test "returns stats for a file", %{workspace_id: workspace_id} do
      VFS.write_file(workspace_id, "/statme.txt", "content")

      {:ok, stat} = VFS.stat(workspace_id, "/statme.txt")
      assert stat.name == "statme.txt"
      assert stat.size == 7
      assert %Jido.VFS.Stat.File{} = stat
    end

    test "returns stats for a directory", %{workspace_id: workspace_id} do
      VFS.mkdir(workspace_id, "/mydir")

      {:ok, stat} = VFS.stat(workspace_id, "/mydir")
      assert stat.name == "mydir"
      assert %Jido.VFS.Stat.Dir{} = stat
    end

    test "returns stats for root", %{workspace_id: workspace_id} do
      {:ok, stat} = VFS.stat(workspace_id, "/")
      assert %Jido.VFS.Stat.Dir{} = stat
    end

    test "returns error for non-existent path", %{workspace_id: workspace_id} do
      assert {:error, error} = VFS.stat(workspace_id, "/nosuchfile.txt")
      assert error.code == {:vfs, :not_found}
    end
  end

  describe "exists?/2" do
    test "returns true for existing file", %{workspace_id: workspace_id} do
      VFS.write_file(workspace_id, "/exists.txt", "yes")
      assert VFS.exists?(workspace_id, "/exists.txt")
    end

    test "returns false for non-existent file", %{workspace_id: workspace_id} do
      refute VFS.exists?(workspace_id, "/nope.txt")
    end
  end

  describe "mkdir/2" do
    test "creates a directory", %{workspace_id: workspace_id} do
      assert :ok = VFS.mkdir(workspace_id, "/newdir")
      assert VFS.exists?(workspace_id, "/newdir")
    end

    test "creates nested directories with files", %{workspace_id: workspace_id} do
      VFS.write_file(workspace_id, "/parent/child/file.txt", "nested")
      assert {:ok, "nested"} = VFS.read_file(workspace_id, "/parent/child/file.txt")
    end

    test "accepts paths that already include trailing slash", %{workspace_id: workspace_id} do
      assert :ok = VFS.mkdir(workspace_id, "/already/")
      assert VFS.exists?(workspace_id, "/already")
    end
  end

  describe "path normalization" do
    test "handles paths with multiple slashes", %{workspace_id: workspace_id} do
      VFS.write_file(workspace_id, "/test.txt", "content")
      assert {:ok, "content"} = VFS.read_file(workspace_id, "///test.txt")
    end

    test "handles relative paths expanded to absolute", %{workspace_id: workspace_id} do
      VFS.write_file(workspace_id, "/dir/file.txt", "content")
      assert {:ok, "content"} = VFS.read_file(workspace_id, "/dir/../dir/file.txt")
    end
  end

  describe "unmount_workspace/2" do
    test "removes all mounts and terminates owned filesystems" do
      workspace_id = "teardown_ws_#{System.unique_integer([:positive])}"
      fs1 = "teardown_fs1_#{System.unique_integer([:positive])}"
      fs2 = "teardown_fs2_#{System.unique_integer([:positive])}"

      assert :ok = VFS.mount(workspace_id, "/one", Jido.VFS.Adapter.InMemory, name: fs1)
      assert :ok = VFS.mount(workspace_id, "/two", Jido.VFS.Adapter.InMemory, name: fs2)

      pid1 = GenServer.whereis(Jido.VFS.Registry.via(Jido.VFS.Adapter.InMemory, fs1))
      pid2 = GenServer.whereis(Jido.VFS.Registry.via(Jido.VFS.Adapter.InMemory, fs2))
      ref1 = Process.monitor(pid1)
      ref2 = Process.monitor(pid2)

      assert :ok = VFS.unmount_workspace(workspace_id)
      assert [] = VFS.list_mounts(workspace_id)
      assert_receive {:DOWN, ^ref1, :process, ^pid1, _reason}
      assert_receive {:DOWN, ^ref2, :process, ^pid2, _reason}
    end

    test "returns invalid workspace error for bad identifiers" do
      assert {:error, %Jido.Shell.Error{code: {:session, :invalid_workspace_id}}} =
               VFS.unmount_workspace(:bad_workspace)
    end
  end

  describe "list_mounts/1" do
    test "returns empty list for invalid workspace identifiers" do
      assert [] = VFS.list_mounts(nil)
      assert [] = VFS.list_mounts("   ")
    end
  end
end
