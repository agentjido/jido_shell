defmodule Jido.Shell.Command.BashTest do
  use Jido.Shell.Case, async: false

  alias Jido.Shell.Command.Bash
  alias Jido.Shell.Session
  alias Jido.Shell.Session.State
  alias Jido.Shell.SessionServer
  alias Jido.Shell.VFS

  setup do
    VFS.init()
    workspace_id = :"bash_ws_#{System.unique_integer([:positive])}"
    fs_name = :"bash_fs_#{System.unique_integer([:positive])}"

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
    test "returns bash" do
      assert Bash.name() == "bash"
    end
  end

  describe "summary/0" do
    test "returns a description" do
      assert is_binary(Bash.summary())
    end
  end

  describe "schema/0" do
    test "returns a Zoi schema" do
      schema = Bash.schema()
      assert {:ok, %{args: []}} = Zoi.parse(schema, %{})
      assert {:ok, %{args: ["-c", "echo hi"]}} = Zoi.parse(schema, %{args: ["-c", "echo hi"]})
    end
  end

  describe "run/3" do
    test "runs inline script with state updates", %{state: state} do
      script = "mkdir docs; cd docs; write hello.txt hello; cat hello.txt"

      {result, events} =
        capture_events(fn emit ->
          Bash.run(state, %{args: ["-c", script]}, emit)
        end)

      assert {:ok, {:state_update, %{cwd: "/docs"}}} = result
      assert {:output, "wrote 5 bytes to /docs/hello.txt\n"} in events
      assert {:output, "hello"} in events
    end

    test "runs script from vfs file", %{state: state, workspace_id: workspace_id} do
      :ok = VFS.mkdir(workspace_id, "/scripts")

      :ok =
        VFS.write_file(
          workspace_id,
          "/scripts/setup.sh",
          """
          mkdir data
          write data/a.txt alpha
          ls data
          """
        )

      {result, events} =
        capture_events(fn emit ->
          Bash.run(state, %{args: ["/scripts/setup.sh"]}, emit)
        end)

      assert {:ok, nil} = result
      assert {:output, "wrote 5 bytes to /data/a.txt\n"} in events
      assert {:output, "a.txt\n"} in events
    end

    test "returns error when script file does not exist", %{state: state} do
      result = Bash.run(state, %{args: ["/scripts/missing.sh"]}, fn _event -> :ok end)

      assert {:error, %Jido.Shell.Error{code: {:vfs, :not_found}}} = result
    end

    test "stops when script uses unsupported command", %{state: state} do
      {result, events} =
        capture_events(fn emit ->
          Bash.run(state, %{args: ["-c", "echo ok; uname -a"]}, emit)
        end)

      assert {:output, "ok\n"} in events
      assert {:error, %Jido.Shell.Error{code: {:shell, :unknown_command}}} = result
    end
  end

  describe "integration with session" do
    test "applies script state updates to session", %{workspace_id: workspace_id} do
      {:ok, session_id} = Session.start(workspace_id)
      :ok = SessionServer.subscribe(session_id, self())

      :ok = SessionServer.run_command(session_id, "bash -c \"mkdir home; cd home\"")

      assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}
      assert_receive {:jido_shell_session, ^session_id, {:cwd_changed, "/home"}}
      assert_receive {:jido_shell_session, ^session_id, :command_done}

      {:ok, state} = SessionServer.get_state(session_id)
      assert state.cwd == "/home"
    end
  end

  defp capture_events(fun) do
    emit = fn event ->
      send(self(), {:event, event})
      :ok
    end

    result = fun.(emit)
    {result, receive_all_events([])}
  end

  defp receive_all_events(acc) do
    receive do
      {:event, event} -> receive_all_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
