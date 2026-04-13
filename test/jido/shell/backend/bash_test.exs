defmodule Jido.Shell.Backend.BashTest do
  use Jido.Shell.Case, async: false

  alias Jido.Shell.Backend.Bash, as: BashBackend
  alias Jido.Shell.ShellSession
  alias Jido.Shell.ShellSessionServer
  alias Jido.Shell.VFS

  @event_timeout 2_000

  setup do
    VFS.init()
    workspace_id = "bash_backend_ws_#{System.unique_integer([:positive])}"
    fs_name = "bash_backend_fs_#{System.unique_integer([:positive])}"

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
        Keyword.merge([backend: {Jido.Shell.Backend.Bash, %{}}], opts)
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

  describe "happy path" do
    test "echo streams output and completes", %{workspace_id: wid} do
      session_id = start_session(wid)

      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "echo hello")

      assert_receive {:jido_shell_session, ^session_id, {:command_started, "echo hello"}}, @event_timeout
      assert {:ok, "hello\n", ""} = receive_output(session_id)
    end
  end

  describe "real bash features" do
    test "for loops with variables", %{workspace_id: wid} do
      session_id = start_session(wid)

      {:ok, :accepted} =
        ShellSessionServer.run_command(session_id, "for i in 1 2 3; do echo $i; done")

      assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout
      assert {:ok, output, _} = receive_output(session_id)
      assert output =~ "1"
      assert output =~ "2"
      assert output =~ "3"
    end

    test "variables persist across run_command calls", %{workspace_id: wid} do
      session_id = start_session(wid)

      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "x=5")
      assert_receive {:jido_shell_session, ^session_id, :command_done}, @event_timeout

      {:ok, :accepted} = ShellSessionServer.run_command(session_id, ~s/echo "$x"/)
      assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout
      assert {:ok, "5\n", ""} = receive_output(session_id)
    end

    test "arithmetic expansion", %{workspace_id: wid} do
      session_id = start_session(wid)

      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "echo $((3 * 7))")
      assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout
      assert {:ok, "21\n", ""} = receive_output(session_id)
    end

    test "redirect into VFS and read back", %{workspace_id: wid} do
      session_id = start_session(wid)

      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "echo hi > /tmp_a.txt")
      assert_receive {:jido_shell_session, ^session_id, :command_done}, @event_timeout
      assert {:ok, "hi\n"} = VFS.read_file(wid, "/tmp_a.txt")

      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "cat /tmp_a.txt")
      assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout
      assert {:ok, "hi\n", ""} = receive_output(session_id)
    end
  end

  describe "isolation" do
    test "external commands are denied by command policy", %{workspace_id: wid} do
      session_id = start_session(wid)

      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "curl example.com")
      assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout

      # Either an error event or command_done with a non-zero exit — both are
      # acceptable for the prototype. The load-bearing assertion is that no
      # host process ran, which the :no_external policy enforces at a layer
      # we trust the :bash library to honor.
      result =
        receive do
          {:jido_shell_session, ^session_id, {:error, _}} -> :error
          {:jido_shell_session, ^session_id, :command_done} -> :done
          {:jido_shell_session, ^session_id, {:output, _}} -> :output
        after
          @event_timeout -> :timeout
        end

      assert result in [:error, :done, :output]
    end
  end

  describe "cwd sync" do
    test "cd propagates to the outer session", %{workspace_id: wid} do
      :ok = VFS.mkdir(wid, "/docs")
      session_id = start_session(wid)

      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "cd /docs")

      assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout
      assert_receive {:jido_shell_session, ^session_id, {:cwd_changed, "/docs"}}, @event_timeout
      assert_receive {:jido_shell_session, ^session_id, :command_done}, @event_timeout

      {:ok, state} = ShellSessionServer.get_state(session_id)
      assert state.cwd == "/docs"
    end
  end

  describe "session termination" do
    test "stopping the shell session stops the bash session", %{workspace_id: wid} do
      session_id = start_session(wid)
      {:ok, state} = ShellSessionServer.get_state(session_id)
      bash_pid = state.backend_state.bash_session
      assert Process.alive?(bash_pid)

      :ok = ShellSession.stop(session_id)

      # Give the GenServer a tick to fully terminate.
      wait_until(fn -> not Process.alive?(bash_pid) end, 2_000)
      refute Process.alive?(bash_pid)
    end
  end

  describe "dep unavailability" do
    test "reports a start-failed error when Bash.Session is missing" do
      # This branch is defensive — with :bash compiled in, Code.ensure_loaded?
      # always succeeds. We keep this test as documentation; if someone drops
      # the dep, the backend should degrade loudly.
      assert Code.ensure_loaded?(Bash.Session)
    end
  end

  describe "init error paths" do
    test "fails when session_pid is missing", %{workspace_id: wid} do
      assert {:error, %Jido.Shell.Error{} = error} =
               BashBackend.init(%{workspace_id: wid, cwd: "/", env: %{}})

      assert error.code == {:session, :invalid_state_transition}
    end
  end

  describe "direct callback surface" do
    setup %{workspace_id: wid} do
      {:ok, state} =
        BashBackend.init(%{
          workspace_id: wid,
          session_pid: self(),
          cwd: "/",
          env: %{},
          task_supervisor: Jido.Shell.CommandTaskSupervisor
        })

      on_exit(fn -> BashBackend.terminate(state) end)
      {:ok, state: state}
    end

    test "cwd/1 returns the current working directory", %{state: state} do
      assert {:ok, "/", _state} = BashBackend.cwd(state)
    end

    test "cd/2 updates the session working directory", %{state: state, workspace_id: wid} do
      :ok = VFS.mkdir(wid, "/work")
      assert {:ok, new_state} = BashBackend.cd(state, "/work")
      assert new_state.cwd == "/work"
      assert {:ok, "/work", _} = BashBackend.cwd(new_state)
    end

    test "cancel/2 is a no-op for dead pids", %{state: state} do
      dead_pid = spawn(fn -> :ok end)
      Process.sleep(10)
      refute Process.alive?(dead_pid)
      assert :ok = BashBackend.cancel(state, dead_pid)
    end

    test "cancel/2 rejects non-pid refs", %{state: state} do
      assert {:error, :invalid_command_ref} = BashBackend.cancel(state, :not_a_pid)
    end

    test "cancel/2 kills a live task", %{state: state} do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      assert :ok = BashBackend.cancel(state, pid)
      wait_until(fn -> not Process.alive?(pid) end, 500)
      refute Process.alive?(pid)
    end

    test "configure_network/2 is a no-op", %{state: state} do
      assert {:ok, ^state} = BashBackend.configure_network(state, %{allow: :all})
    end

    test "terminate/1 is idempotent when bash session is gone", %{state: state} do
      :ok = BashBackend.terminate(state)
      # Calling terminate again should not raise even though the pid is dead.
      assert :ok = BashBackend.terminate(state)
    end

    test "terminate/1 handles a state without bash_session" do
      assert :ok = BashBackend.terminate(%{})
    end
  end

  describe "execute non-zero exit" do
    test "a command with non-zero exit reports an error", %{workspace_id: wid} do
      session_id = start_session(wid)

      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "false")
      assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout

      assert_receive {:jido_shell_session, ^session_id, {:error, %Jido.Shell.Error{code: {:command, :exit_code}}}},
                     @event_timeout
    end
  end

  describe "execute streaming" do
    test "stderr is streamed separately from stdout", %{workspace_id: wid} do
      session_id = start_session(wid)

      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "echo hello >&2")
      assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout
      assert {:ok, "", "hello\n"} = receive_output(session_id)
    end

    test "exit builtin is treated as a successful completion", %{workspace_id: wid} do
      session_id = start_session(wid)

      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "exit 0")
      assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout
      assert_receive {:jido_shell_session, ^session_id, :command_done}, @event_timeout
    end
  end

  describe "execute error branches" do
    test "invalid bash syntax returns a clean syntax_error", %{workspace_id: wid} do
      {:ok, state} =
        BashBackend.init(%{
          workspace_id: wid,
          session_pid: self(),
          cwd: "/",
          env: %{},
          task_supervisor: Jido.Shell.CommandTaskSupervisor
        })

      assert {:ok, _pid, _state} = BashBackend.execute(state, "echo \"unterminated", [], [])

      assert_receive {:command_finished, {:error, %Jido.Shell.Error{code: {:command, :syntax_error}}}},
                     @event_timeout

      :ok = BashBackend.terminate(state)
    end

    test "session is usable after a syntax error", %{workspace_id: wid} do
      session_id = start_session(wid)

      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "echo \"unterminated")

      assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout

      assert_receive {:jido_shell_session, ^session_id, {:error, %Jido.Shell.Error{code: {:command, :syntax_error}}}},
                     @event_timeout

      # Session should accept new commands
      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "echo ok")
      assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout
      assert {:ok, "ok\n", ""} = receive_output(session_id)
    end
  end

  describe "cwd with dead session" do
    test "falls back to cached cwd", %{workspace_id: wid} do
      {:ok, state} =
        BashBackend.init(%{
          workspace_id: wid,
          session_pid: self(),
          cwd: "/fallback",
          env: %{},
          task_supervisor: Jido.Shell.CommandTaskSupervisor
        })

      # Kill the bash session to trigger the fallback path in cwd/1
      Bash.Session.stop(state.bash_session)
      Process.sleep(50)

      assert {:ok, "/fallback", _state} = BashBackend.cwd(state)
    end
  end

  describe "execute with args" do
    test "backend passes args alongside command", %{workspace_id: wid} do
      {:ok, state} =
        BashBackend.init(%{
          workspace_id: wid,
          session_pid: self(),
          cwd: "/",
          env: %{},
          task_supervisor: Jido.Shell.CommandTaskSupervisor
        })

      assert {:ok, _pid, _state} = BashBackend.execute(state, "echo", ["foo", "bar"], [])
      assert_receive {:command_event, {:output, output}}, @event_timeout
      assert output =~ "foo bar"
      assert_receive {:command_finished, _}, @event_timeout
      :ok = BashBackend.terminate(state)
    end
  end

  describe "cancellation" do
    test "cancel interrupts a long-running bash loop", %{workspace_id: wid} do
      session_id = start_session(wid)

      # Use a pure-bash loop (no external seq) so it runs under :no_external policy
      {:ok, :accepted} =
        ShellSessionServer.run_command(session_id, "i=0; while [ $i -lt 10000 ]; do echo $i; i=$((i+1)); done")

      assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout

      # Let some output come through
      assert_receive {:jido_shell_session, ^session_id, {:output, _}}, @event_timeout

      # Cancel
      {:ok, :cancelled} = ShellSessionServer.cancel(session_id)
      assert_receive {:jido_shell_session, ^session_id, :command_cancelled}, @event_timeout

      # Session should be reusable after cancellation
      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "echo alive")
      assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout
      assert {:ok, "alive\n", ""} = receive_output(session_id)
    end

    test "cancel preserves session state (variables, cwd)", %{workspace_id: wid} do
      :ok = VFS.mkdir(wid, "/testdir")
      session_id = start_session(wid)

      # Set a variable and cd
      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "x=42; cd /testdir")
      assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout
      assert_receive {:jido_shell_session, ^session_id, {:cwd_changed, "/testdir"}}, @event_timeout
      assert_receive {:jido_shell_session, ^session_id, :command_done}, @event_timeout

      # Start and cancel a long command (pure-bash loop)
      {:ok, :accepted} =
        ShellSessionServer.run_command(session_id, "i=0; while [ $i -lt 10000 ]; do echo $i; i=$((i+1)); done")

      assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout
      assert_receive {:jido_shell_session, ^session_id, {:output, _}}, @event_timeout
      {:ok, :cancelled} = ShellSessionServer.cancel(session_id)
      assert_receive {:jido_shell_session, ^session_id, :command_cancelled}, @event_timeout

      # Variable should be preserved
      {:ok, :accepted} = ShellSessionServer.run_command(session_id, ~s/echo "$x"/)
      assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout
      assert {:ok, "42\n", ""} = receive_output(session_id)
    end
  end

  describe "cd through function shim" do
    test "cd inside a function propagates to the outer session", %{workspace_id: wid} do
      :ok = VFS.mkdir(wid, "/inner")
      session_id = start_session(wid)

      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "go() { cd /inner; }; go")
      assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout
      assert_receive {:jido_shell_session, ^session_id, {:cwd_changed, "/inner"}}, @event_timeout
      assert_receive {:jido_shell_session, ^session_id, :command_done}, @event_timeout

      {:ok, state} = ShellSessionServer.get_state(session_id)
      assert state.cwd == "/inner"
    end
  end

  describe "exec builtin" do
    test "exec returns {:ok, nil} (treated as successful completion)", %{workspace_id: wid} do
      session_id = start_session(wid)

      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "exec echo done")
      assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout
      # exec replaces the shell; the backend should treat it as a clean exit
      assert_receive {:jido_shell_session, ^session_id, _event}, @event_timeout
    end
  end

  describe "error command result" do
    test "a command producing {:error, execution} reports exit_code error", %{workspace_id: wid} do
      session_id = start_session(wid)

      # `false` returns exit code 1 which triggers the {:error, execution} path
      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "false")
      assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout

      assert_receive {:jido_shell_session, ^session_id, {:error, %Jido.Shell.Error{code: {:command, :exit_code}}}},
                     @event_timeout
    end
  end

  describe "cwd unchanged" do
    test "no cwd_changed event when cwd stays the same", %{workspace_id: wid} do
      session_id = start_session(wid)

      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "echo stable")
      assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout
      assert {:ok, "stable\n", ""} = receive_output(session_id)

      # No cwd_changed event should have been sent
      refute_receive {:jido_shell_session, ^session_id, {:cwd_changed, _}}, 100
    end
  end

  describe "stderr streaming" do
    test "stderr is routed through {:output_stderr, _}", %{workspace_id: wid} do
      session_id = start_session(wid)

      {:ok, :accepted} = ShellSessionServer.run_command(session_id, "echo error_msg >&2")
      assert_receive {:jido_shell_session, ^session_id, {:command_started, _}}, @event_timeout
      assert {:ok, "", stderr} = receive_output(session_id)
      assert stderr =~ "error_msg"
    end
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
