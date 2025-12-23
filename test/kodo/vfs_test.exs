defmodule Kodo.VFSTest do
  use Kodo.Case, async: false

  alias Kodo.VFS

  setup do
    VFS.init()
    workspace_id = :"test_ws_#{System.unique_integer([:positive])}"
    fs_name = :"test_fs_#{System.unique_integer([:positive])}"

    start_supervised!({Depot.Adapter.InMemory, {Depot.Adapter.InMemory, %Depot.Adapter.InMemory.Config{name: fs_name}}})

    :ok = VFS.mount(workspace_id, "/", Depot.Adapter.InMemory, name: fs_name)

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
      unknown_ws = :"unknown_ws_#{System.unique_integer([:positive])}"
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
      assert %Depot.Stat.File{} = stat
    end

    test "returns stats for a directory", %{workspace_id: workspace_id} do
      VFS.mkdir(workspace_id, "/mydir")

      {:ok, stat} = VFS.stat(workspace_id, "/mydir")
      assert stat.name == "mydir"
      assert %Depot.Stat.Dir{} = stat
    end

    test "returns stats for root", %{workspace_id: workspace_id} do
      {:ok, stat} = VFS.stat(workspace_id, "/")
      assert %Depot.Stat.Dir{} = stat
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
end
