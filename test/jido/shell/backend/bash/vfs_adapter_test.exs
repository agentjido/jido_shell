defmodule Jido.Shell.Backend.Bash.VfsAdapterTest do
  use Jido.Shell.Case, async: false

  alias Jido.Shell.Backend.Bash.VfsAdapter
  alias Jido.Shell.VFS

  setup do
    VFS.init()
    workspace_id = "bash_vfs_ws_#{System.unique_integer([:positive])}"
    fs_name = "bash_vfs_fs_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Jido.VFS.Adapter.InMemory, {Jido.VFS.Adapter.InMemory, %Jido.VFS.Adapter.InMemory.Config{name: fs_name}}}
    )

    :ok = VFS.mount(workspace_id, "/", Jido.VFS.Adapter.InMemory, name: fs_name)

    on_exit(fn -> VFS.unmount(workspace_id, "/") end)

    {:ok, config: %{workspace_id: workspace_id}, workspace_id: workspace_id}
  end

  describe "write/4 and read/2" do
    test "round-trips content", %{config: cfg} do
      assert :ok = VfsAdapter.write(cfg, "/hello.txt", "hi", [])
      assert {:ok, "hi"} = VfsAdapter.read(cfg, "/hello.txt")
    end

    test "append mode concatenates", %{config: cfg} do
      :ok = VfsAdapter.write(cfg, "/log.txt", "one\n", [])
      :ok = VfsAdapter.write(cfg, "/log.txt", "two\n", append: true)
      assert {:ok, "one\ntwo\n"} = VfsAdapter.read(cfg, "/log.txt")
    end

    test "reports enoent for missing files", %{config: cfg} do
      assert {:error, :enoent} = VfsAdapter.read(cfg, "/missing.txt")
    end
  end

  describe "exists?/2, dir?/2, regular?/2" do
    test "distinguishes files and directories", %{config: cfg, workspace_id: wid} do
      :ok = VFS.mkdir(wid, "/docs")
      :ok = VFS.write_file(wid, "/docs/readme.md", "hello")

      assert VfsAdapter.exists?(cfg, "/docs")
      assert VfsAdapter.exists?(cfg, "/docs/readme.md")
      refute VfsAdapter.exists?(cfg, "/docs/missing.txt")

      assert VfsAdapter.dir?(cfg, "/docs")
      refute VfsAdapter.dir?(cfg, "/docs/readme.md")

      assert VfsAdapter.regular?(cfg, "/docs/readme.md")
      refute VfsAdapter.regular?(cfg, "/docs")
    end
  end

  describe "stat/2" do
    test "returns File.Stat for directories", %{config: cfg, workspace_id: wid} do
      :ok = VFS.mkdir(wid, "/d")
      assert {:ok, %File.Stat{type: :directory}} = VfsAdapter.stat(cfg, "/d")
    end

    test "returns File.Stat for regular files", %{config: cfg, workspace_id: wid} do
      :ok = VFS.write_file(wid, "/f.txt", "abcd")
      assert {:ok, %File.Stat{type: :regular, size: 4}} = VfsAdapter.stat(cfg, "/f.txt")
    end

    test "maps missing paths to enoent", %{config: cfg} do
      assert {:error, :enoent} = VfsAdapter.stat(cfg, "/nope")
    end
  end

  describe "mkdir_p/2" do
    test "creates a new directory", %{config: cfg} do
      assert :ok = VfsAdapter.mkdir_p(cfg, "/new")
      assert VfsAdapter.dir?(cfg, "/new")
    end

    test "is idempotent when the directory already exists", %{config: cfg, workspace_id: wid} do
      :ok = VFS.mkdir(wid, "/existing")
      assert :ok = VfsAdapter.mkdir_p(cfg, "/existing")
    end
  end

  describe "rm/2" do
    test "removes a file", %{config: cfg, workspace_id: wid} do
      :ok = VFS.write_file(wid, "/gone.txt", "x")
      assert :ok = VfsAdapter.rm(cfg, "/gone.txt")
      refute VfsAdapter.exists?(cfg, "/gone.txt")
    end

    test "tolerates missing files the way the underlying VFS does", %{config: cfg} do
      # The in-memory VFS adapter returns :ok for missing paths, so rm/2 is
      # idempotent. If a future adapter returns an error, the adapter maps it
      # to {:error, :enoent}.
      assert VfsAdapter.rm(cfg, "/nope") in [:ok, {:error, :enoent}]
    end
  end

  describe "ls/2" do
    test "returns sorted entry names", %{config: cfg, workspace_id: wid} do
      :ok = VFS.mkdir(wid, "/d")
      :ok = VFS.write_file(wid, "/d/b.txt", "")
      :ok = VFS.write_file(wid, "/d/a.txt", "")

      assert {:ok, ["a.txt", "b.txt"]} = VfsAdapter.ls(cfg, "/d")
    end
  end

  describe "wildcard/3" do
    test "matches simple star patterns", %{config: cfg, workspace_id: wid} do
      :ok = VFS.write_file(wid, "/a.log", "")
      :ok = VFS.write_file(wid, "/b.log", "")
      :ok = VFS.write_file(wid, "/c.txt", "")

      matches = VfsAdapter.wildcard(cfg, "/*.log", [])
      assert Enum.sort(matches) == ["/a.log", "/b.log"]
    end

    test "returns [] for unsupported patterns", %{config: cfg} do
      assert [] = VfsAdapter.wildcard(cfg, "/**/*.log", [])
    end
  end

  describe "open/write/close round trip" do
    test "buffers writes until close", %{config: cfg} do
      {:ok, device} = VfsAdapter.open(cfg, "/buffered.txt", [:write])
      :ok = VfsAdapter.handle_write(cfg, device, "part1 ")
      :ok = VfsAdapter.handle_write(cfg, device, "part2")
      :ok = VfsAdapter.handle_close(cfg, device)

      assert {:ok, "part1 part2"} = VfsAdapter.read(cfg, "/buffered.txt")
    end

    test "open :read on a missing file reports enoent", %{config: cfg} do
      assert {:error, :enoent} = VfsAdapter.open(cfg, "/missing", [:read])
    end
  end

  describe "link callbacks" do
    test "are not supported", %{config: cfg} do
      assert {:error, :enotsup} = VfsAdapter.read_link(cfg, "/anything")
      assert {:error, :enotsup} = VfsAdapter.read_link_all(cfg, "/anything")
    end
  end

  describe "lstat/2" do
    test "mirrors stat/2", %{config: cfg, workspace_id: wid} do
      :ok = VFS.write_file(wid, "/linked.txt", "abc")
      assert {:ok, %File.Stat{type: :regular, size: 3}} = VfsAdapter.lstat(cfg, "/linked.txt")
    end
  end

  describe "open/3 modes" do
    test "opening with :append flushes appended data on close", %{config: cfg} do
      :ok = VfsAdapter.write(cfg, "/append.txt", "line1\n", [])
      {:ok, device} = VfsAdapter.open(cfg, "/append.txt", [:append])
      :ok = VfsAdapter.handle_write(cfg, device, "line2\n")
      :ok = VfsAdapter.handle_close(cfg, device)
      assert {:ok, "line1\nline2\n"} = VfsAdapter.read(cfg, "/append.txt")
    end

    test "rejects modes without read/write/append", %{config: cfg} do
      assert {:error, :einval} = VfsAdapter.open(cfg, "/bad", [:exclusive])
    end

    test "rejects non-list modes", %{config: cfg} do
      assert {:error, :einval} = VfsAdapter.open(cfg, "/bad", nil)
    end
  end

  describe "handle_write/handle_close fallbacks" do
    test "handle_write on an unknown device falls back to IO.binwrite", %{config: cfg} do
      {:ok, device} = StringIO.open("")
      assert :ok = VfsAdapter.handle_write(cfg, device, "raw")
      {_, written} = StringIO.contents(device)
      assert written == "raw"
      StringIO.close(device)
    end

    test "handle_close on an unknown device closes it without writing to VFS", %{config: cfg} do
      {:ok, device} = StringIO.open("")
      assert :ok = VfsAdapter.handle_close(cfg, device)
    end
  end

  describe "normalize relative paths" do
    test "resolves relative paths against root", %{config: cfg} do
      :ok = VfsAdapter.write(cfg, "hello.txt", "hi", [])
      assert {:ok, "hi"} = VfsAdapter.read(cfg, "hello.txt")
    end
  end

  describe "ls/2 edge cases" do
    test "returns sorted names for existing directory", %{config: cfg, workspace_id: wid} do
      :ok = VFS.mkdir(wid, "/dir2")
      :ok = VFS.write_file(wid, "/dir2/x", "")
      assert {:ok, ["x"]} = VfsAdapter.ls(cfg, "/dir2")
    end
  end

  describe "wildcard/3 extras" do
    test "question-mark patterns match single characters", %{config: cfg, workspace_id: wid} do
      :ok = VFS.write_file(wid, "/ax.txt", "")
      :ok = VFS.write_file(wid, "/bx.txt", "")
      :ok = VFS.write_file(wid, "/ax2.txt", "")

      matches = VfsAdapter.wildcard(cfg, "/?x.txt", [])
      assert Enum.sort(matches) == ["/ax.txt", "/bx.txt"]
    end

    test "returns [] when the parent directory does not exist", %{config: cfg} do
      assert [] = VfsAdapter.wildcard(cfg, "/nonexistent/*.log", [])
    end
  end
end
