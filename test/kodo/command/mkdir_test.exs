defmodule Kodo.Command.MkdirTest do
  use Kodo.Case, async: false

  alias Kodo.Command.Mkdir
  alias Kodo.Session
  alias Kodo.Session.State
  alias Kodo.SessionServer
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
    test "returns mkdir" do
      assert Mkdir.name() == "mkdir"
    end
  end

  describe "summary/0" do
    test "returns a description" do
      assert is_binary(Mkdir.summary())
    end
  end

  describe "schema/0" do
    test "returns a Zoi schema" do
      schema = Mkdir.schema()
      assert {:ok, %{args: []}} = Zoi.parse(schema, %{})
    end
  end

  describe "run/3" do
    test "creates a directory with absolute path", %{state: state, workspace_id: workspace_id} do
      emit = fn event -> send(self(), {:emit, event}) end

      assert {:ok, nil} = Mkdir.run(state, %{args: ["/newdir"]}, emit)
      assert_receive {:emit, {:output, "created: /newdir\n"}}

      assert VFS.exists?(workspace_id, "/newdir")
    end

    test "creates a directory with relative path", %{state: state, workspace_id: workspace_id} do
      emit = fn event -> send(self(), {:emit, event}) end

      assert {:ok, nil} = Mkdir.run(state, %{args: ["mydir"]}, emit)
      assert_receive {:emit, {:output, "created: /mydir\n"}}

      assert VFS.exists?(workspace_id, "/mydir")
    end

    test "creates multiple directories", %{state: state, workspace_id: workspace_id} do
      emit = fn event -> send(self(), {:emit, event}) end

      assert {:ok, nil} = Mkdir.run(state, %{args: ["/dir1", "/dir2", "/dir3"]}, emit)

      assert_receive {:emit, {:output, "created: /dir1\n"}}
      assert_receive {:emit, {:output, "created: /dir2\n"}}
      assert_receive {:emit, {:output, "created: /dir3\n"}}

      assert VFS.exists?(workspace_id, "/dir1")
      assert VFS.exists?(workspace_id, "/dir2")
      assert VFS.exists?(workspace_id, "/dir3")
    end

    test "errors when no directory argument", %{state: state} do
      emit = fn _event -> :ok end

      result = Mkdir.run(state, %{args: []}, emit)

      assert {:error, %Kodo.Error{code: {:validation, :invalid_args}}} = result
    end

    test "creates directory relative to cwd", %{workspace_id: workspace_id} do
      VFS.mkdir(workspace_id, "/parent")
      {:ok, state} = State.new(%{id: "test", workspace_id: workspace_id, cwd: "/parent"})
      emit = fn event -> send(self(), {:emit, event}) end

      assert {:ok, nil} = Mkdir.run(state, %{args: ["child"]}, emit)

      assert VFS.exists?(workspace_id, "/parent/child")
    end
  end

  describe "integration with session" do
    test "mkdir creates directories via session", %{workspace_id: workspace_id} do
      {:ok, session_id} = Session.start(workspace_id)
      :ok = SessionServer.subscribe(session_id, self())

      :ok = SessionServer.run_command(session_id, "mkdir /testdir")

      assert_receive {:kodo_session, ^session_id, {:command_started, _}}
      assert_receive {:kodo_session, ^session_id, {:output, "created: /testdir\n"}}
      assert_receive {:kodo_session, ^session_id, :command_done}

      assert VFS.exists?(workspace_id, "/testdir")
    end
  end
end
