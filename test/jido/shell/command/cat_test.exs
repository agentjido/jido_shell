defmodule Jido.Shell.Command.CatTest do
  use Jido.Shell.Case, async: false

  alias Jido.Shell.Command.Cat
  alias Jido.Shell.Session.State
  alias Jido.Shell.VFS

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
    test "returns cat" do
      assert Cat.name() == "cat"
    end
  end

  describe "summary/0" do
    test "returns a description" do
      assert is_binary(Cat.summary())
    end
  end

  describe "schema/0" do
    test "returns a Zoi schema" do
      schema = Cat.schema()
      assert {:ok, %{args: []}} = Zoi.parse(schema, %{})
    end
  end

  describe "run/3" do
    test "displays file contents", %{state: state, workspace_id: workspace_id} do
      VFS.write_file(workspace_id, "/test.txt", "Hello, World!")

      emit = fn event -> send(self(), {:emit, event}) end

      {:ok, nil} = Cat.run(state, %{args: ["/test.txt"]}, emit)

      assert_receive {:emit, {:output, "Hello, World!"}}
    end

    test "displays multiple files", %{state: state, workspace_id: workspace_id} do
      VFS.write_file(workspace_id, "/file1.txt", "First")
      VFS.write_file(workspace_id, "/file2.txt", "Second")

      emit = fn {:output, content} -> send(self(), {:emit, content}) end

      {:ok, nil} = Cat.run(state, %{args: ["/file1.txt", "/file2.txt"]}, emit)

      received =
        receive do
          {:emit, content} -> content
        after
          100 -> nil
        end

      received2 =
        receive do
          {:emit, content} -> content
        after
          100 -> nil
        end

      contents = [received, received2] |> Enum.sort()
      assert contents == ["First", "Second"]
    end

    test "handles relative paths from cwd", %{workspace_id: workspace_id} do
      VFS.mkdir(workspace_id, "/dir")
      VFS.write_file(workspace_id, "/dir/file.txt", "Content")

      {:ok, state} = State.new(%{id: "test", workspace_id: workspace_id, cwd: "/dir"})
      emit = fn event -> send(self(), {:emit, event}) end

      {:ok, nil} = Cat.run(state, %{args: ["file.txt"]}, emit)

      assert_receive {:emit, {:output, "Content"}}
    end

    test "returns error when no file argument provided", %{state: state} do
      emit = fn event -> send(self(), {:emit, event}) end

      {:error, error} = Cat.run(state, %{args: []}, emit)

      assert error.code == {:validation, :invalid_args}
      assert error.context.command == "cat"
    end

    test "returns error for non-existent file", %{state: state} do
      emit = fn event -> send(self(), {:emit, event}) end

      {:error, error} = Cat.run(state, %{args: ["/nosuchfile.txt"]}, emit)

      assert error.code == {:vfs, :not_found}
    end

    test "returns error if any file in list doesn't exist", %{state: state, workspace_id: workspace_id} do
      VFS.write_file(workspace_id, "/exists.txt", "yes")

      emit = fn event -> send(self(), {:emit, event}) end

      {:error, error} = Cat.run(state, %{args: ["/missing.txt", "/exists.txt"]}, emit)

      assert error.code == {:vfs, :not_found}
    end
  end
end
