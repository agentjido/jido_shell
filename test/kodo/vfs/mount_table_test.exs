defmodule Kodo.VFS.MountTableTest do
  use Kodo.Case, async: false

  alias Kodo.VFS.MountTable

  setup do
    Kodo.VFS.init()
    workspace_id = :"test_ws_#{System.unique_integer([:positive])}"
    fs_name = :"test_fs_#{System.unique_integer([:positive])}"

    {:ok, workspace_id: workspace_id, fs_name: fs_name}
  end

  describe "init/0" do
    test "creates the ETS table" do
      assert :ok = MountTable.init()
      assert :ets.whereis(:kodo_vfs_mounts) != :undefined
    end

    test "is idempotent" do
      assert :ok = MountTable.init()
      assert :ok = MountTable.init()
    end
  end

  describe "mount/4" do
    test "mounts a filesystem at a path", %{workspace_id: workspace_id, fs_name: fs_name} do
      start_supervised!({Hako.Adapter.InMemory, {Hako.Adapter.InMemory, %Hako.Adapter.InMemory.Config{name: fs_name}}})

      assert :ok = MountTable.mount(workspace_id, "/", Hako.Adapter.InMemory, name: fs_name)
      assert [mount] = MountTable.list(workspace_id)
      assert mount.path == "/"
      assert mount.adapter == Hako.Adapter.InMemory
    end

    test "mounts multiple filesystems at different paths", %{workspace_id: workspace_id} do
      fs1 = :"fs1_#{System.unique_integer([:positive])}"
      fs2 = :"fs2_#{System.unique_integer([:positive])}"

      start_supervised!({Hako.Adapter.InMemory, {Hako.Adapter.InMemory, %Hako.Adapter.InMemory.Config{name: fs1}}},
        id: :fs1
      )

      start_supervised!({Hako.Adapter.InMemory, {Hako.Adapter.InMemory, %Hako.Adapter.InMemory.Config{name: fs2}}},
        id: :fs2
      )

      assert :ok = MountTable.mount(workspace_id, "/", Hako.Adapter.InMemory, name: fs1)
      assert :ok = MountTable.mount(workspace_id, "/data", Hako.Adapter.InMemory, name: fs2)

      mounts = MountTable.list(workspace_id)
      assert length(mounts) == 2
    end
  end

  describe "unmount/2" do
    test "unmounts an existing mount", %{workspace_id: workspace_id, fs_name: fs_name} do
      start_supervised!({Hako.Adapter.InMemory, {Hako.Adapter.InMemory, %Hako.Adapter.InMemory.Config{name: fs_name}}})

      :ok = MountTable.mount(workspace_id, "/", Hako.Adapter.InMemory, name: fs_name)

      assert :ok = MountTable.unmount(workspace_id, "/")
      assert [] = MountTable.list(workspace_id)
    end

    test "returns error for non-existent mount", %{workspace_id: workspace_id} do
      assert {:error, :not_found} = MountTable.unmount(workspace_id, "/nonexistent")
    end
  end

  describe "list/1" do
    test "returns empty list for workspace with no mounts", %{workspace_id: workspace_id} do
      assert [] = MountTable.list(workspace_id)
    end

    test "returns mounts sorted by path length (longest first)", %{workspace_id: workspace_id} do
      fs1 = :"fs1_#{System.unique_integer([:positive])}"
      fs2 = :"fs2_#{System.unique_integer([:positive])}"
      fs3 = :"fs3_#{System.unique_integer([:positive])}"

      start_supervised!({Hako.Adapter.InMemory, {Hako.Adapter.InMemory, %Hako.Adapter.InMemory.Config{name: fs1}}},
        id: :fs1
      )

      start_supervised!({Hako.Adapter.InMemory, {Hako.Adapter.InMemory, %Hako.Adapter.InMemory.Config{name: fs2}}},
        id: :fs2
      )

      start_supervised!({Hako.Adapter.InMemory, {Hako.Adapter.InMemory, %Hako.Adapter.InMemory.Config{name: fs3}}},
        id: :fs3
      )

      :ok = MountTable.mount(workspace_id, "/", Hako.Adapter.InMemory, name: fs1)
      :ok = MountTable.mount(workspace_id, "/data", Hako.Adapter.InMemory, name: fs2)
      :ok = MountTable.mount(workspace_id, "/data/logs", Hako.Adapter.InMemory, name: fs3)

      mounts = MountTable.list(workspace_id)
      paths = Enum.map(mounts, & &1.path)
      assert paths == ["/data/logs", "/data", "/"]
    end
  end

  describe "resolve/2" do
    test "resolves path to root mount", %{workspace_id: workspace_id, fs_name: fs_name} do
      start_supervised!({Hako.Adapter.InMemory, {Hako.Adapter.InMemory, %Hako.Adapter.InMemory.Config{name: fs_name}}})

      :ok = MountTable.mount(workspace_id, "/", Hako.Adapter.InMemory, name: fs_name)

      {:ok, mount, relative} = MountTable.resolve(workspace_id, "/test.txt")
      assert mount.path == "/"
      assert relative == "test.txt"

      {:ok, mount2, relative2} = MountTable.resolve(workspace_id, "/")
      assert mount2.path == "/"
      assert relative2 == "."
    end

    test "resolves path to nested mount", %{workspace_id: workspace_id} do
      fs1 = :"fs1_#{System.unique_integer([:positive])}"
      fs2 = :"fs2_#{System.unique_integer([:positive])}"

      start_supervised!({Hako.Adapter.InMemory, {Hako.Adapter.InMemory, %Hako.Adapter.InMemory.Config{name: fs1}}},
        id: :fs1
      )

      start_supervised!({Hako.Adapter.InMemory, {Hako.Adapter.InMemory, %Hako.Adapter.InMemory.Config{name: fs2}}},
        id: :fs2
      )

      :ok = MountTable.mount(workspace_id, "/", Hako.Adapter.InMemory, name: fs1)
      :ok = MountTable.mount(workspace_id, "/data", Hako.Adapter.InMemory, name: fs2)

      {:ok, mount, relative} = MountTable.resolve(workspace_id, "/data/file.txt")
      assert mount.path == "/data"
      assert relative == "file.txt"
    end

    test "returns error when no mount matches", %{workspace_id: workspace_id} do
      assert {:error, :no_mount} = MountTable.resolve(workspace_id, "/test.txt")
    end

    test "resolves mount point itself", %{workspace_id: workspace_id} do
      fs_name = :"fs_#{System.unique_integer([:positive])}"

      start_supervised!({Hako.Adapter.InMemory, {Hako.Adapter.InMemory, %Hako.Adapter.InMemory.Config{name: fs_name}}})

      :ok = MountTable.mount(workspace_id, "/data", Hako.Adapter.InMemory, name: fs_name)

      {:ok, mount, relative} = MountTable.resolve(workspace_id, "/data")
      assert mount.path == "/data"
      assert relative == "."
    end
  end
end
