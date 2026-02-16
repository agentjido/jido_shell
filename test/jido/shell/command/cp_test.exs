defmodule Jido.Shell.Command.CpTest do
  use Jido.Shell.Case, async: false

  alias Jido.Shell.Command.Cp
  alias Jido.Shell.ShellSession.State
  alias Jido.Shell.VFS

  setup do
    VFS.init()
    workspace_id = "test_ws_#{System.unique_integer([:positive])}"
    fs_name = "test_fs_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Jido.VFS.Adapter.InMemory, {Jido.VFS.Adapter.InMemory, %Jido.VFS.Adapter.InMemory.Config{name: fs_name}}}
    )

    :ok = VFS.mount(workspace_id, "/", Jido.VFS.Adapter.InMemory, name: fs_name)

    {:ok, state} = State.new(%{id: "test", workspace_id: workspace_id, cwd: "/"})

    on_exit(fn ->
      VFS.unmount(workspace_id, "/")
    end)

    {:ok, state: state, workspace_id: workspace_id}
  end

  describe "name/0" do
    test "returns cp" do
      assert Cp.name() == "cp"
    end
  end

  describe "summary/0" do
    test "returns a description" do
      assert is_binary(Cp.summary())
    end
  end

  describe "schema/0" do
    test "returns a Zoi schema" do
      schema = Cp.schema()
      assert {:ok, %{args: []}} = Zoi.parse(schema, %{})
    end
  end

  describe "run/3" do
    test "copies a file", %{state: state, workspace_id: workspace_id} do
      VFS.write_file(workspace_id, "/source.txt", "Hello!")
      emit = fn event -> send(self(), {:emit, event}) end

      {:ok, nil} = Cp.run(state, %{args: ["/source.txt", "/dest.txt"]}, emit)

      assert_receive {:emit, {:output, "copied: /source.txt -> /dest.txt\n"}}
      assert {:ok, "Hello!"} = VFS.read_file(workspace_id, "/dest.txt")
      assert {:ok, "Hello!"} = VFS.read_file(workspace_id, "/source.txt")
    end

    test "handles relative paths from cwd", %{workspace_id: workspace_id} do
      VFS.mkdir(workspace_id, "/dir")
      VFS.write_file(workspace_id, "/dir/source.txt", "content")

      {:ok, state} = State.new(%{id: "test", workspace_id: workspace_id, cwd: "/dir"})
      emit = fn event -> send(self(), {:emit, event}) end

      {:ok, nil} = Cp.run(state, %{args: ["source.txt", "dest.txt"]}, emit)

      assert_receive {:emit, {:output, output}}
      assert output =~ "copied:"
      assert {:ok, "content"} = VFS.read_file(workspace_id, "/dir/dest.txt")
    end

    test "copies binary content", %{state: state, workspace_id: workspace_id} do
      binary = <<0, 1, 2, 3, 255>>
      VFS.write_file(workspace_id, "/binary.bin", binary)
      emit = fn _event -> :ok end

      {:ok, nil} = Cp.run(state, %{args: ["/binary.bin", "/copy.bin"]}, emit)

      assert {:ok, ^binary} = VFS.read_file(workspace_id, "/copy.bin")
    end

    test "returns error when no arguments provided", %{state: state} do
      emit = fn _event -> :ok end

      {:error, error} = Cp.run(state, %{args: []}, emit)

      assert error.code == {:validation, :invalid_args}
      assert error.context.command == "cp"
    end

    test "returns error when only one argument provided", %{state: state} do
      emit = fn _event -> :ok end

      {:error, error} = Cp.run(state, %{args: ["/source.txt"]}, emit)

      assert error.code == {:validation, :invalid_args}
    end

    test "returns error when too many arguments provided", %{state: state} do
      emit = fn _event -> :ok end

      {:error, error} = Cp.run(state, %{args: ["/a", "/b", "/c"]}, emit)

      assert error.code == {:validation, :invalid_args}
    end

    test "returns error for non-existent source", %{state: state} do
      emit = fn _event -> :ok end

      {:error, error} = Cp.run(state, %{args: ["/nosuchfile.txt", "/dest.txt"]}, emit)

      assert error.code == {:vfs, :not_found}
    end

    test "overwrites existing destination", %{state: state, workspace_id: workspace_id} do
      VFS.write_file(workspace_id, "/source.txt", "new content")
      VFS.write_file(workspace_id, "/dest.txt", "old content")
      emit = fn _event -> :ok end

      {:ok, nil} = Cp.run(state, %{args: ["/source.txt", "/dest.txt"]}, emit)

      assert {:ok, "new content"} = VFS.read_file(workspace_id, "/dest.txt")
    end
  end
end
