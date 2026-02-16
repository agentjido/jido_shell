defmodule Jido.Shell.VFS.MountTest do
  use Jido.Shell.Case, async: false

  alias Jido.Shell.VFS.Mount

  defmodule InvalidConfigAdapter do
    def starts_processes, do: false
    def configure(_opts), do: :invalid
  end

  defmodule StatelessAdapter do
    def starts_processes, do: false
    def configure(opts), do: {__MODULE__, %{name: Keyword.get(opts, :name, "stateless")}}
  end

  defmodule BrokenProcessAdapter do
    def starts_processes, do: true
    def configure(opts), do: {__MODULE__, %{name: Keyword.get(opts, :name, "broken")}}
  end

  setup do
    Jido.Shell.VFS.init()
    fs_name = "test_fs_#{System.unique_integer([:positive])}"

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

    test "returns invalid adapter config errors" do
      assert {:error, {:invalid_adapter_config, :invalid}} =
               Mount.new("/bad", InvalidConfigAdapter, [])
    end

    test "returns mounts with no owned child for adapters without process startup" do
      assert {:ok, mount} = Mount.new("/stateless", StatelessAdapter, name: "stateless")
      assert mount.ownership == :none
      assert mount.child_pid == nil
    end

    test "returns child startup errors for process adapters without child specs" do
      assert {:error, _reason} = Mount.new("/broken", BrokenProcessAdapter, name: "broken")
    end
  end
end
