defmodule Jido.Shell.Command.MkdirTest do
  use Jido.Shell.Case, async: false

  alias Jido.Shell.Command.Mkdir
  alias Jido.Shell.ShellSession
  alias Jido.Shell.ShellSession.State
  alias Jido.Shell.ShellSessionServer
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

      assert {:error, %Jido.Shell.Error{code: {:validation, :invalid_args}}} = result
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
      {:ok, session_id} = ShellSession.start(workspace_id)
      {:ok, :subscribed} = ShellSessionServer.subscribe(session_id, self())

      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "mkdir /testdir")

      assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}
      assert_receive {:jido_shell_session, ^session_id, {:output, "created: /testdir\n"}}
      assert_receive {:jido_shell_session, ^session_id, :command_done}

      assert VFS.exists?(workspace_id, "/testdir")
    end
  end
end
