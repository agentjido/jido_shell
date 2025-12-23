defmodule Kodo.Command.RmTest do
  use Kodo.Case, async: false

  alias Kodo.Command.Rm
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
    test "returns rm" do
      assert Rm.name() == "rm"
    end
  end

  describe "summary/0" do
    test "returns a description" do
      assert is_binary(Rm.summary())
    end
  end

  describe "schema/0" do
    test "returns a Zoi schema" do
      schema = Rm.schema()
      assert {:ok, %{args: []}} = Zoi.parse(schema, %{})
    end
  end

  describe "run/3" do
    test "removes a file", %{state: state, workspace_id: workspace_id} do
      VFS.write_file(workspace_id, "/test.txt", "content")
      emit = fn event -> send(self(), {:emit, event}) end

      {:ok, nil} = Rm.run(state, %{args: ["/test.txt"]}, emit)

      assert_receive {:emit, {:output, "removed: /test.txt\n"}}
      assert {:error, _} = VFS.read_file(workspace_id, "/test.txt")
    end

    test "removes multiple files", %{state: state, workspace_id: workspace_id} do
      VFS.write_file(workspace_id, "/file1.txt", "content1")
      VFS.write_file(workspace_id, "/file2.txt", "content2")
      emit = fn event -> send(self(), {:emit, event}) end

      {:ok, nil} = Rm.run(state, %{args: ["/file1.txt", "/file2.txt"]}, emit)

      assert_receive {:emit, {:output, "removed: /file1.txt\n"}}
      assert_receive {:emit, {:output, "removed: /file2.txt\n"}}
      assert {:error, _} = VFS.read_file(workspace_id, "/file1.txt")
      assert {:error, _} = VFS.read_file(workspace_id, "/file2.txt")
    end

    test "handles relative paths from cwd", %{workspace_id: workspace_id} do
      VFS.mkdir(workspace_id, "/dir")
      VFS.write_file(workspace_id, "/dir/file.txt", "content")

      {:ok, state} = State.new(%{id: "test", workspace_id: workspace_id, cwd: "/dir"})
      emit = fn event -> send(self(), {:emit, event}) end

      {:ok, nil} = Rm.run(state, %{args: ["file.txt"]}, emit)

      assert_receive {:emit, {:output, output}}
      assert output =~ "removed:"
      assert {:error, _} = VFS.read_file(workspace_id, "/dir/file.txt")
    end

    test "returns error when no file argument provided", %{state: state} do
      emit = fn _event -> :ok end

      {:error, error} = Rm.run(state, %{args: []}, emit)

      assert error.code == {:validation, :invalid_args}
      assert error.context.command == "rm"
    end

    test "returns error for non-existent file", %{state: state} do
      emit = fn _event -> :ok end

      {:error, error} = Rm.run(state, %{args: ["/nosuchfile.txt"]}, emit)

      assert error.code == {:vfs, :not_found}
    end

    test "returns error if any file in list doesn't exist", %{state: state, workspace_id: workspace_id} do
      VFS.write_file(workspace_id, "/exists.txt", "yes")
      emit = fn event -> send(self(), {:emit, event}) end

      {:error, error} = Rm.run(state, %{args: ["/missing.txt", "/exists.txt"]}, emit)

      assert error.code == {:vfs, :not_found}
    end
  end
end
