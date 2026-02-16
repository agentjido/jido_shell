defmodule Jido.Shell.Command.WriteTest do
  use Jido.Shell.Case, async: false

  alias Jido.Shell.Command.Write
  alias Jido.Shell.Session
  alias Jido.Shell.Session.State
  alias Jido.Shell.SessionServer
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
    test "returns write" do
      assert Write.name() == "write"
    end
  end

  describe "summary/0" do
    test "returns a description" do
      assert is_binary(Write.summary())
    end
  end

  describe "schema/0" do
    test "returns a Zoi schema" do
      schema = Write.schema()
      assert {:ok, %{args: []}} = Zoi.parse(schema, %{})
    end
  end

  describe "run/3" do
    test "writes content to a file with absolute path", %{
      state: state,
      workspace_id: workspace_id
    } do
      emit = fn event -> send(self(), {:emit, event}) end

      assert {:ok, nil} = Write.run(state, %{args: ["/hello.txt", "Hello", "World"]}, emit)
      assert_receive {:emit, {:output, "wrote 11 bytes to /hello.txt\n"}}

      assert {:ok, "Hello World"} = VFS.read_file(workspace_id, "/hello.txt")
    end

    test "writes content to a file with relative path", %{
      state: state,
      workspace_id: workspace_id
    } do
      emit = fn event -> send(self(), {:emit, event}) end

      assert {:ok, nil} = Write.run(state, %{args: ["file.txt", "content"]}, emit)
      assert_receive {:emit, {:output, "wrote 7 bytes to /file.txt\n"}}

      assert {:ok, "content"} = VFS.read_file(workspace_id, "/file.txt")
    end

    test "writes file relative to cwd", %{workspace_id: workspace_id} do
      VFS.mkdir(workspace_id, "/subdir")
      {:ok, state} = State.new(%{id: "test", workspace_id: workspace_id, cwd: "/subdir"})
      emit = fn event -> send(self(), {:emit, event}) end

      assert {:ok, nil} = Write.run(state, %{args: ["nested.txt", "data"]}, emit)

      assert {:ok, "data"} = VFS.read_file(workspace_id, "/subdir/nested.txt")
    end

    test "errors when no file argument", %{state: state} do
      emit = fn _event -> :ok end

      result = Write.run(state, %{args: []}, emit)

      assert {:error, %Jido.Shell.Error{code: {:validation, :invalid_args}}} = result
    end

    test "errors when only file argument (no content)", %{state: state} do
      emit = fn _event -> :ok end

      result = Write.run(state, %{args: ["file.txt"]}, emit)

      assert {:error, %Jido.Shell.Error{code: {:validation, :invalid_args}}} = result
    end

    test "overwrites existing file", %{state: state, workspace_id: workspace_id} do
      VFS.write_file(workspace_id, "/existing.txt", "old content")
      emit = fn event -> send(self(), {:emit, event}) end

      assert {:ok, nil} = Write.run(state, %{args: ["/existing.txt", "new", "content"]}, emit)

      assert {:ok, "new content"} = VFS.read_file(workspace_id, "/existing.txt")
    end
  end

  describe "integration with session" do
    test "write creates files via session", %{workspace_id: workspace_id} do
      {:ok, session_id} = Session.start(workspace_id)
      {:ok, :subscribed} = SessionServer.subscribe(session_id, self())

      {:ok, :accepted} = SessionServer.run_command(session_id, "write /test.txt hello world")

      assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}
      assert_receive {:jido_shell_session, ^session_id, {:output, _}}
      assert_receive {:jido_shell_session, ^session_id, :command_done}

      assert {:ok, "hello world"} = VFS.read_file(workspace_id, "/test.txt")
    end
  end
end
