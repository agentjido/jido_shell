defmodule Jido.Shell.Command.CdTest do
  use Jido.Shell.Case, async: false

  alias Jido.Shell.Command.Cd
  alias Jido.Shell.Session
  alias Jido.Shell.Session.State
  alias Jido.Shell.SessionServer
  alias Jido.Shell.VFS

  setup do
    VFS.init()
    workspace_id = :"test_ws_#{System.unique_integer([:positive])}"
    fs_name = :"test_fs_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Jido.VFS.Adapter.InMemory, {Jido.VFS.Adapter.InMemory, %Jido.VFS.Adapter.InMemory.Config{name: fs_name}}}
    )

    :ok = VFS.mount(workspace_id, "/", Jido.VFS.Adapter.InMemory, name: fs_name)

    :ok = VFS.mkdir(workspace_id, "/home")
    :ok = VFS.mkdir(workspace_id, "/home/user")
    :ok = VFS.write_file(workspace_id, "/file.txt", "content")

    {:ok, state} = State.new(%{id: "test", workspace_id: workspace_id, cwd: "/"})

    on_exit(fn ->
      VFS.unmount(workspace_id, "/")
    end)

    {:ok, state: state, workspace_id: workspace_id}
  end

  describe "name/0" do
    test "returns cd" do
      assert Cd.name() == "cd"
    end
  end

  describe "summary/0" do
    test "returns a description" do
      assert is_binary(Cd.summary())
    end
  end

  describe "schema/0" do
    test "returns a Zoi schema" do
      schema = Cd.schema()
      assert {:ok, %{args: []}} = Zoi.parse(schema, %{})
    end
  end

  describe "run/3" do
    test "returns to root when no args", %{state: state} do
      state = %{state | cwd: "/home/user"}
      emit = fn _event -> :ok end

      assert {:ok, {:state_update, %{cwd: "/"}}} = Cd.run(state, %{args: []}, emit)
    end

    test "changes to absolute path", %{state: state} do
      emit = fn _event -> :ok end

      assert {:ok, {:state_update, %{cwd: "/home"}}} = Cd.run(state, %{args: ["/home"]}, emit)
    end

    test "changes to relative path", %{state: state} do
      emit = fn _event -> :ok end

      assert {:ok, {:state_update, %{cwd: "/home"}}} = Cd.run(state, %{args: ["home"]}, emit)
    end

    test "handles ..", %{state: state} do
      state = %{state | cwd: "/home/user"}
      emit = fn _event -> :ok end

      assert {:ok, {:state_update, %{cwd: "/home"}}} = Cd.run(state, %{args: [".."]}, emit)
    end

    test "handles nested relative path", %{state: state} do
      emit = fn _event -> :ok end

      assert {:ok, {:state_update, %{cwd: "/home/user"}}} =
               Cd.run(state, %{args: ["home/user"]}, emit)
    end

    test "errors on non-existent path", %{state: state} do
      emit = fn _event -> :ok end

      result = Cd.run(state, %{args: ["/nonexistent"]}, emit)

      assert {:error, %Jido.Shell.Error{code: {:vfs, :not_found}}} = result
    end

    test "errors on file (not directory)", %{state: state} do
      emit = fn _event -> :ok end

      result = Cd.run(state, %{args: ["/file.txt"]}, emit)

      assert {:error, %Jido.Shell.Error{code: {:vfs, :not_a_directory}}} = result
    end
  end

  describe "integration with session" do
    test "cd changes session cwd", %{workspace_id: workspace_id} do
      {:ok, session_id} = Session.start(workspace_id)
      :ok = SessionServer.subscribe(session_id, self())

      :ok = SessionServer.run_command(session_id, "cd /home")

      assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}
      assert_receive {:jido_shell_session, ^session_id, :command_done}
      assert_receive {:jido_shell_session, ^session_id, {:cwd_changed, "/home"}}

      {:ok, state} = SessionServer.get_state(session_id)
      assert state.cwd == "/home"
    end

    test "cwd_changed event is broadcast", %{workspace_id: workspace_id} do
      {:ok, session_id} = Session.start(workspace_id)
      :ok = SessionServer.subscribe(session_id, self())

      :ok = SessionServer.run_command(session_id, "cd /home/user")

      assert_receive {:jido_shell_session, ^session_id, {:cwd_changed, "/home/user"}}
    end

    test "relative path resolved from current cwd", %{workspace_id: workspace_id} do
      {:ok, session_id} = Session.start(workspace_id, cwd: "/home")
      :ok = SessionServer.subscribe(session_id, self())

      :ok = SessionServer.run_command(session_id, "cd user")

      assert_receive {:jido_shell_session, ^session_id, :command_done}
      assert_receive {:jido_shell_session, ^session_id, {:cwd_changed, "/home/user"}}

      {:ok, state} = SessionServer.get_state(session_id)
      assert state.cwd == "/home/user"
    end

    test "error on cd to non-existent path", %{workspace_id: workspace_id} do
      {:ok, session_id} = Session.start(workspace_id)
      :ok = SessionServer.subscribe(session_id, self())

      :ok = SessionServer.run_command(session_id, "cd /nonexistent")

      assert_receive {:jido_shell_session, ^session_id, {:error, %Jido.Shell.Error{code: {:vfs, :not_found}}}}
    end
  end
end
