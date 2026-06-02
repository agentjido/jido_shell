defmodule Jido.Shell.Backend.LuaTest do
  use Jido.Shell.Case, async: false

  alias Jido.Shell.ShellSession
  alias Jido.Shell.ShellSessionServer
  alias Jido.Shell.VFS

  @event_timeout 2_000

  setup do
    VFS.init()
    workspace_id = "lua_backend_ws_#{System.unique_integer([:positive])}"
    fs_name = "lua_backend_fs_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Jido.VFS.Adapter.InMemory, {Jido.VFS.Adapter.InMemory, %Jido.VFS.Adapter.InMemory.Config{name: fs_name}}}
    )

    :ok = VFS.mount(workspace_id, "/", Jido.VFS.Adapter.InMemory, name: fs_name)

    on_exit(fn -> VFS.unmount(workspace_id, "/") end)

    {:ok, workspace_id: workspace_id}
  end

  defp start_session(workspace_id, opts \\ []) do
    {:ok, session_id} =
      ShellSession.start(
        workspace_id,
        Keyword.merge([backend: {Jido.Shell.Backend.Lua, %{}}], opts)
      )

    {:ok, :subscribed} = ShellSessionServer.subscribe(session_id, self())
    session_id
  end

  defp receive_output(session_id, acc \\ "", stderr_acc \\ "") do
    receive do
      {:jido_shell_session, ^session_id, {:output, chunk}} ->
        receive_output(session_id, acc <> IO.iodata_to_binary(chunk), stderr_acc)

      {:jido_shell_session, ^session_id, {:output_stderr, chunk}} ->
        receive_output(session_id, acc, stderr_acc <> IO.iodata_to_binary(chunk))

      {:jido_shell_session, ^session_id, :command_done} ->
        {:ok, acc, stderr_acc}

      {:jido_shell_session, ^session_id, {:error, err}} ->
        {:error, err, acc}
    after
      @event_timeout -> {:timeout, acc}
    end
  end

  test "print streams output and completes", %{workspace_id: wid} do
    session_id = start_session(wid)

    {:ok, :accepted} = ShellSessionServer.run_command(session_id, ~S/print("hello")/)

    assert_receive {:jido_shell_session, ^session_id, {:command_started, ~S/print("hello")/}}, @event_timeout
    assert {:ok, "hello\n", ""} = receive_output(session_id)
  end

  test "globals persist across run_command calls", %{workspace_id: wid} do
    session_id = start_session(wid)

    {:ok, :accepted} = ShellSessionServer.run_command(session_id, "x = 5")
    assert_receive {:jido_shell_session, ^session_id, :command_done}, @event_timeout

    {:ok, :accepted} = ShellSessionServer.run_command(session_id, "print(x)")
    assert_receive {:jido_shell_session, ^session_id, {:command_started, "print(x)"}}, @event_timeout
    assert {:ok, "5\n", ""} = receive_output(session_id)
  end

  test "jido commands stream through the VFS-backed command runner", %{workspace_id: wid} do
    :ok = VFS.write_file(wid, "/note.txt", "from vfs")
    session_id = start_session(wid)

    {:ok, :accepted} = ShellSessionServer.run_command(session_id, ~S/jido.echo("hello", "lua")/)
    assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout
    assert {:ok, "hello lua\n", ""} = receive_output(session_id)

    {:ok, :accepted} = ShellSessionServer.run_command(session_id, ~S|jido.cat("/note.txt")|)
    assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout
    assert {:ok, "from vfs", ""} = receive_output(session_id)
  end

  test "jido cd updates the outer session cwd", %{workspace_id: wid} do
    :ok = VFS.mkdir(wid, "/docs")
    session_id = start_session(wid)

    {:ok, :accepted} = ShellSessionServer.run_command(session_id, ~S|jido.cd("/docs")|)

    assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout
    assert_receive {:jido_shell_session, ^session_id, {:cwd_changed, "/docs"}}, @event_timeout
    assert_receive {:jido_shell_session, ^session_id, :command_done}, @event_timeout

    {:ok, state} = ShellSessionServer.get_state(session_id)
    assert state.cwd == "/docs"

    {:ok, :accepted} = ShellSessionServer.run_command(session_id, "jido.pwd()")
    assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout
    assert {:ok, "/docs\n", ""} = receive_output(session_id)
  end

  test "jido arguments preserve parser separators and quotes", %{workspace_id: wid} do
    session_id = start_session(wid)

    {:ok, :accepted} =
      ShellSessionServer.run_command(session_id, ~S|jido.echo("foo;bar", "one&&two", "quote\"here", "path\\name")|)

    assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout
    assert {:ok, ~s(foo;bar one&&two quote"here path\\name\n), ""} = receive_output(session_id)
  end

  test "sandboxed host access fails without side effects", %{workspace_id: wid} do
    session_id = start_session(wid)
    host_path = "/tmp/jido_shell_lua_escape_#{System.unique_integer([:positive])}"

    refute File.exists?(host_path)

    {:ok, :accepted} =
      ShellSessionServer.run_command(session_id, ~s|os.execute("touch #{host_path}")|)

    assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout

    assert_receive {:jido_shell_session, ^session_id, {:error, %Jido.Shell.Error{code: {:command, :runtime_error}}}},
                   @event_timeout

    refute File.exists?(host_path)

    {:ok, :accepted} = ShellSessionServer.run_command(session_id, ~S|print("alive")|)
    assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout
    assert {:ok, "alive\n", ""} = receive_output(session_id)
  end

  test "output limit aborts before streaming oversized output", %{workspace_id: wid} do
    session_id = start_session(wid)

    {:ok, :accepted} = ShellSessionServer.run_command(session_id, "x = 1")
    assert_receive {:jido_shell_session, ^session_id, :command_done}, @event_timeout

    {:ok, :accepted} =
      ShellSessionServer.run_command(session_id, ~S|x = 2; print("abcdef")|,
        execution_context: %{limits: %{max_output_bytes: 3}}
      )

    assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout

    assert_receive {:jido_shell_session, ^session_id,
                    {:error, %Jido.Shell.Error{code: {:command, :output_limit_exceeded}}}},
                   @event_timeout

    refute_receive {:jido_shell_session, ^session_id, {:output, _}}, 100

    {:ok, :accepted} = ShellSessionServer.run_command(session_id, "print(x)")
    assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout
    assert {:ok, "1\n", ""} = receive_output(session_id)
  end

  test "runtime limit kills an infinite loop and keeps the session reusable", %{workspace_id: wid} do
    session_id = start_session(wid)

    {:ok, :accepted} =
      ShellSessionServer.run_command(session_id, "while true do end",
        execution_context: %{limits: %{max_runtime_ms: 50}}
      )

    assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout

    assert_receive {:jido_shell_session, ^session_id,
                    {:error, %Jido.Shell.Error{code: {:command, :runtime_limit_exceeded}}}},
                   @event_timeout

    {:ok, state} = ShellSessionServer.get_state(session_id)
    assert Process.alive?(state.backend_state.lua_session)

    {:ok, :accepted} = ShellSessionServer.run_command(session_id, ~S|print("alive")|)
    assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout
    assert {:ok, "alive\n", ""} = receive_output(session_id)
  end

  test "cancel kills a running Lua eval and keeps the session reusable", %{workspace_id: wid} do
    session_id = start_session(wid)

    {:ok, :accepted} = ShellSessionServer.run_command(session_id, "while true do end")
    assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout

    {:ok, :cancelled} = ShellSessionServer.cancel(session_id)
    assert_receive {:jido_shell_session, ^session_id, :command_cancelled}, @event_timeout

    {:ok, :accepted} = ShellSessionServer.run_command(session_id, ~S|print("alive")|)
    assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout
    assert {:ok, "alive\n", ""} = receive_output(session_id)
  end

  test "stopping the shell session stops the Lua holder", %{workspace_id: wid} do
    session_id = start_session(wid)
    {:ok, state} = ShellSessionServer.get_state(session_id)
    lua_pid = state.backend_state.lua_session
    assert Process.alive?(lua_pid)

    :ok = ShellSession.stop(session_id)

    wait_until(fn -> not Process.alive?(lua_pid) end, 2_000)
    refute Process.alive?(lua_pid)
  end

  test "persistent: false — globals do not carry over between run_command calls", %{workspace_id: wid} do
    session_id = start_session(wid, backend: {Jido.Shell.Backend.Lua, %{persistent: false}})

    {:ok, :accepted} = ShellSessionServer.run_command(session_id, "x = 99")
    assert_receive {:jido_shell_session, ^session_id, :command_done}, @event_timeout

    {:ok, :accepted} = ShellSessionServer.run_command(session_id, "print(x)")
    assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout
    # fresh VM each call — x is nil, our print renders nil as ""
    assert {:ok, "\n", ""} = receive_output(session_id)
  end

  defp wait_until(fun, timeout, interval \\ 20, elapsed \\ 0)

  defp wait_until(_fun, timeout, _interval, elapsed) when elapsed >= timeout, do: :timeout

  defp wait_until(fun, timeout, interval, elapsed) do
    if fun.() do
      :ok
    else
      Process.sleep(interval)
      wait_until(fun, timeout, interval, elapsed + interval)
    end
  end
end
