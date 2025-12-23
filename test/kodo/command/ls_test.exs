defmodule Kodo.Command.LsTest do
  use Kodo.Case, async: false

  alias Kodo.Command.Ls
  alias Kodo.Session.State
  alias Kodo.VFS

  setup do
    VFS.init()
    workspace_id = :"test_ws_#{System.unique_integer([:positive])}"
    fs_name = :"test_fs_#{System.unique_integer([:positive])}"

    start_supervised!({Hako.Adapter.InMemory, {Hako.Adapter.InMemory, %Hako.Adapter.InMemory.Config{name: fs_name}}})
    :ok = VFS.mount(workspace_id, "/", Hako.Adapter.InMemory, name: fs_name)

    {:ok, state} = State.new(%{id: "test", workspace_id: workspace_id, cwd: "/"})

    on_exit(fn ->
      VFS.unmount(workspace_id, "/")
    end)

    {:ok, state: state, workspace_id: workspace_id}
  end

  describe "name/0" do
    test "returns ls" do
      assert Ls.name() == "ls"
    end
  end

  describe "summary/0" do
    test "returns a description" do
      assert is_binary(Ls.summary())
    end
  end

  describe "schema/0" do
    test "returns a Zoi schema" do
      schema = Ls.schema()
      assert {:ok, %{args: []}} = Zoi.parse(schema, %{})
    end
  end

  describe "run/3" do
    test "lists current directory when no args", %{state: state, workspace_id: workspace_id} do
      VFS.write_file(workspace_id, "/file1.txt", "a")
      VFS.write_file(workspace_id, "/file2.txt", "b")

      emit = fn event -> send(self(), {:emit, event}) end

      {:ok, entries} = Ls.run(state, %{args: []}, emit)

      assert length(entries) == 2
      assert_receive {:emit, {:output, output}}
      assert output =~ "file1.txt"
      assert output =~ "file2.txt"
    end

    test "lists specified directory", %{state: state, workspace_id: workspace_id} do
      VFS.mkdir(workspace_id, "/subdir")
      VFS.write_file(workspace_id, "/subdir/nested.txt", "content")

      emit = fn event -> send(self(), {:emit, event}) end

      {:ok, entries} = Ls.run(state, %{args: ["/subdir"]}, emit)

      assert length(entries) == 1
      assert_receive {:emit, {:output, output}}
      assert output =~ "nested.txt"
    end

    test "lists relative path from cwd", %{workspace_id: workspace_id} do
      VFS.mkdir(workspace_id, "/parent")
      VFS.write_file(workspace_id, "/parent/child.txt", "content")

      {:ok, state} = State.new(%{id: "test", workspace_id: workspace_id, cwd: "/parent"})
      emit = fn event -> send(self(), {:emit, event}) end

      {:ok, entries} = Ls.run(state, %{args: ["."]}, emit)

      assert length(entries) == 1
      assert_receive {:emit, {:output, output}}
      assert output =~ "child.txt"
    end

    test "handles empty directory", %{state: state, workspace_id: workspace_id} do
      VFS.mkdir(workspace_id, "/empty")

      emit = fn event -> send(self(), {:emit, event}) end

      {:ok, entries} = Ls.run(state, %{args: ["/empty"]}, emit)

      assert entries == []
      refute_receive {:emit, _}
    end

    test "shows directories with trailing slash", %{state: state, workspace_id: workspace_id} do
      VFS.mkdir(workspace_id, "/mydir")

      emit = fn event -> send(self(), {:emit, event}) end

      {:ok, _entries} = Ls.run(state, %{args: []}, emit)

      assert_receive {:emit, {:output, output}}
      assert output =~ "mydir/"
    end

    test "returns empty list for non-existent directory", %{state: state} do
      emit = fn event -> send(self(), {:emit, event}) end

      {:ok, entries} = Ls.run(state, %{args: ["/nosuchdir"]}, emit)

      assert entries == []
    end
  end
end
