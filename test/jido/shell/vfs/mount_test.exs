defmodule Jido.Shell.VFS.MountTest do
  use Jido.Shell.Case, async: false

  alias Jido.Shell.VFS.Mount

  setup do
    Jido.Shell.VFS.init()
    fs_name = :"test_fs_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Jido.VFS.Adapter.InMemory, {Jido.VFS.Adapter.InMemory, %Jido.VFS.Adapter.InMemory.Config{name: fs_name}}}
    )

    {:ok, fs_name: fs_name}
  end

  describe "new/3" do
    test "creates a mount with valid adapter", %{fs_name: fs_name} do
      {:ok, mount} = Mount.new("/data", Jido.VFS.Adapter.InMemory, name: fs_name)

      assert mount.path == "/data"
      assert mount.adapter == Jido.VFS.Adapter.InMemory
      assert mount.opts == [name: fs_name]
      assert is_tuple(mount.filesystem)
    end

    test "normalizes path by removing trailing slash", %{fs_name: fs_name} do
      {:ok, mount} = Mount.new("/data/", Jido.VFS.Adapter.InMemory, name: fs_name)
      assert mount.path == "/data"
    end

    test "keeps root path as is", %{fs_name: fs_name} do
      {:ok, mount} = Mount.new("/", Jido.VFS.Adapter.InMemory, name: fs_name)
      assert mount.path == "/"
    end
  end
end
