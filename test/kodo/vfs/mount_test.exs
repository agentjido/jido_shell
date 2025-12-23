defmodule Kodo.VFS.MountTest do
  use Kodo.Case, async: false

  alias Kodo.VFS.Mount

  setup do
    Kodo.VFS.init()
    fs_name = :"test_fs_#{System.unique_integer([:positive])}"

    start_supervised!({Depot.Adapter.InMemory, {Depot.Adapter.InMemory, %Depot.Adapter.InMemory.Config{name: fs_name}}})

    {:ok, fs_name: fs_name}
  end

  describe "new/3" do
    test "creates a mount with valid adapter", %{fs_name: fs_name} do
      {:ok, mount} = Mount.new("/data", Depot.Adapter.InMemory, name: fs_name)

      assert mount.path == "/data"
      assert mount.adapter == Depot.Adapter.InMemory
      assert mount.opts == [name: fs_name]
      assert is_tuple(mount.filesystem)
    end

    test "normalizes path by removing trailing slash", %{fs_name: fs_name} do
      {:ok, mount} = Mount.new("/data/", Depot.Adapter.InMemory, name: fs_name)
      assert mount.path == "/data"
    end

    test "keeps root path as is", %{fs_name: fs_name} do
      {:ok, mount} = Mount.new("/", Depot.Adapter.InMemory, name: fs_name)
      assert mount.path == "/"
    end
  end
end
