defmodule Jido.Shell.Backend.SSHTest do
  use Jido.Shell.Case, async: false

  alias Jido.Shell.Backend.SSH

  # ---------------------------------------------------------------------------
  # FakeSSH — mimics Erlang's :ssh and :ssh_connection modules for unit testing.
  #
  # Injected via :ssh_module and :ssh_connection_module config keys so we test
  # the real Backend.SSH code path without a real SSH server.
  # ---------------------------------------------------------------------------

  defmodule FakeSSH do
    @moduledoc false

    # -- :ssh API surface --

    def connect(host, port, opts, _timeout) do
      case mode() do
        :connect_error ->
          {:error, :econnrefused}

        _ ->
          conn = spawn(fn -> Process.sleep(:infinity) end)
          notify({:connect, host, port, opts, conn})
          {:ok, conn}
      end
    end

    def close(conn) do
      case mode() do
        :close_throw ->
          throw(:close_failed)

        _ ->
          notify({:close, conn})
          :ok
      end
    end

    # -- :ssh_connection API surface --

    def session_channel(conn, _timeout) do
      case mode() do
        :session_channel_error ->
          {:error, :session_channel_failed}

        :session_channel_raise ->
          raise "session channel crash"

        _ ->
          channel_id = :erlang.unique_integer([:positive])
          notify({:session_channel, conn, channel_id})
          {:ok, channel_id}
      end
    end

    def setenv(_conn, _channel_id, _var, _value, _timeout), do: :success

    def exec(conn, channel_id, command, _timeout) do
      command_str = to_string(command)
      notify({:exec, conn, channel_id, command_str})

      caller = self()

      case mode() do
        :exec_failure ->
          :failure

        :exec_error ->
          {:error, :exec_rejected}

        :no_events ->
          :success

        _ ->
          cond do
            String.contains?(command_str, "echo ssh") ->
              send(caller, {:ssh_cm, conn, {:data, channel_id, 0, "ssh\n"}})
              send(caller, {:ssh_cm, conn, {:exit_status, channel_id, 0}})
              send(caller, {:ssh_cm, conn, {:eof, channel_id}})
              send(caller, {:ssh_cm, conn, {:closed, channel_id}})

            String.contains?(command_str, "fail ssh") ->
              send(caller, {:ssh_cm, conn, {:data, channel_id, 1, "failed\n"}})
              send(caller, {:ssh_cm, conn, {:exit_status, channel_id, 7}})
              send(caller, {:ssh_cm, conn, {:eof, channel_id}})
              send(caller, {:ssh_cm, conn, {:closed, channel_id}})

            String.contains?(command_str, "fail trailing ssh") ->
              send(caller, {:ssh_cm, conn, {:exit_status, channel_id, 7}})
              send(caller, {:ssh_cm, conn, {:data, channel_id, 1, "small\n"}})
              send(caller, {:ssh_cm, conn, {:eof, channel_id}})
              send(caller, {:ssh_cm, conn, {:closed, channel_id}})

            String.contains?(command_str, "fail limit ssh") ->
              send(caller, {:ssh_cm, conn, {:exit_status, channel_id, 7}})
              send(caller, {:ssh_cm, conn, {:data, channel_id, 1, "123456"}})
              send(caller, {:ssh_cm, conn, {:eof, channel_id}})
              send(caller, {:ssh_cm, conn, {:closed, channel_id}})

            String.contains?(command_str, "limit ssh") ->
              send(caller, {:ssh_cm, conn, {:data, channel_id, 0, "123456"}})
              send(caller, {:ssh_cm, conn, {:exit_status, channel_id, 0}})
              send(caller, {:ssh_cm, conn, {:eof, channel_id}})
              send(caller, {:ssh_cm, conn, {:closed, channel_id}})

            String.contains?(command_str, "sleep ssh") ->
              Process.send_after(caller, {:ssh_cm, conn, {:data, channel_id, 0, "sleeping\n"}}, 5)
              Process.send_after(caller, {:ssh_cm, conn, {:exit_status, channel_id, 0}}, 250)
              Process.send_after(caller, {:ssh_cm, conn, {:eof, channel_id}}, 260)
              Process.send_after(caller, {:ssh_cm, conn, {:closed, channel_id}}, 270)

            true ->
              send(caller, {:ssh_cm, conn, {:exit_status, channel_id, 0}})
              send(caller, {:ssh_cm, conn, {:eof, channel_id}})
              send(caller, {:ssh_cm, conn, {:closed, channel_id}})
          end

          :success
      end
    end

    def close(conn, channel_id) do
      notify({:close_channel, conn, channel_id})
      :ok
    end

    defp notify(event) do
      case :persistent_term.get({__MODULE__, :test_pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:fake_ssh, event})
        _ -> :ok
      end
    end

    defp mode do
      :persistent_term.get({__MODULE__, :mode}, :normal)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  @fake_config %{
    ssh_module: FakeSSH,
    ssh_connection_module: FakeSSH
  }

  setup do
    :persistent_term.put({FakeSSH, :test_pid}, self())
    :persistent_term.put({FakeSSH, :mode}, :normal)

    on_exit(fn ->
      :persistent_term.erase({FakeSSH, :test_pid})
      :persistent_term.erase({FakeSSH, :mode})
    end)

    :ok
  end

  defp init_fake(overrides \\ %{}) do
    config = Map.merge(%{session_pid: self(), host: "test-host", user: "root"}, @fake_config)
    SSH.init(Map.merge(config, overrides))
  end

  defp set_fake_mode(mode) do
    :persistent_term.put({FakeSSH, :mode}, mode)
  end

  defp rsa_private_key_pem do
    key = :public_key.generate_key({:rsa, 1_024, 65_537})
    :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
  end

  test "init connects and terminate closes" do
    {:ok, state} = init_fake(%{port: 22})

    assert_receive {:fake_ssh, {:connect, ~c"test-host", 22, _opts, _conn}}
    assert state.host == "test-host"
    assert state.user == "root"
    assert state.cwd == "/"

    assert :ok = SSH.terminate(state)
    assert_receive {:fake_ssh, {:close, _}}
  end

  test "execute streams stdout and returns command_done" do
    {:ok, state} = init_fake()

    {:ok, worker_pid, _state} = SSH.execute(state, "echo ssh", [], [])
    assert is_pid(worker_pid)

    assert_receive {:command_event, {:output, "ssh\n"}}
    assert_receive {:command_finished, {:ok, nil}}

    ref = Process.monitor(worker_pid)
    assert_receive {:DOWN, ^ref, :process, ^worker_pid, _}
  end

  test "execute maps non-zero exits to structured errors" do
    {:ok, state} = init_fake()

    {:ok, _worker_pid, _state} = SSH.execute(state, "fail ssh", [], [])

    assert_receive {:command_event, {:output, "failed\n"}}
    assert_receive {:command_finished, {:error, %Jido.Shell.Error{code: {:command, :exit_code}}}}
  end

  test "enforces output limit when non-zero exit arrives before trailing oversized data" do
    {:ok, state} = init_fake()

    {:ok, _worker_pid, _state} = SSH.execute(state, "fail limit ssh", [], output_limit: 3)

    assert_receive {:command_finished, {:error, %Jido.Shell.Error{code: {:command, :output_limit_exceeded}}}}
  end

  test "preserves non-zero exit when trailing data remains under the output limit" do
    {:ok, state} = init_fake()

    {:ok, _worker_pid, _state} = SSH.execute(state, "fail trailing ssh", [], output_limit: 100)

    assert_receive {:command_event, {:output, "small\n"}}
    assert_receive {:command_finished, {:error, %Jido.Shell.Error{code: {:command, :exit_code}} = error}}
    assert error.context.code == 7
  end

  test "execute enforces output limits" do
    {:ok, state} = init_fake()

    {:ok, _worker_pid, _state} = SSH.execute(state, "limit ssh", [], output_limit: 3)

    assert_receive {:command_finished, {:error, %Jido.Shell.Error{code: {:command, :output_limit_exceeded}}}}
  end

  test "cancel closes channel and stops worker" do
    {:ok, state} = init_fake()

    {:ok, worker_pid, _state} = SSH.execute(state, "sleep ssh", [], [])
    assert_receive {:fake_ssh, {:exec, _, _, _}}

    # Give the worker a moment to register in ETS
    Process.sleep(20)

    assert :ok = SSH.cancel(state, worker_pid)
    assert_receive {:fake_ssh, {:close_channel, _, _}}
  end

  test "cwd and cd track working directory" do
    {:ok, state} = init_fake(%{cwd: "/home"})

    assert {:ok, "/home", ^state} = SSH.cwd(state)

    {:ok, updated} = SSH.cd(state, "/tmp")
    assert {:ok, "/tmp", ^updated} = SSH.cwd(updated)
  end

  test "execute updates cwd from exec_opts" do
    {:ok, state} = init_fake(%{cwd: "/home"})

    {:ok, _worker_pid, updated_state} = SSH.execute(state, "echo ssh", [], dir: "/tmp")

    assert updated_state.cwd == "/tmp"
    assert_receive {:command_finished, {:ok, nil}}
  end

  test "execute with env variables" do
    {:ok, state} = init_fake(%{env: %{"FOO" => "bar"}})

    {:ok, _worker_pid, updated_state} = SSH.execute(state, "echo ssh", [], [])

    assert updated_state.env == %{"FOO" => "bar"}
    assert_receive {:command_finished, {:ok, nil}}
  end

  test "state stores connect_params for reconnection" do
    {:ok, state} = init_fake()

    assert state.connect_params.host == "test-host"
    assert state.connect_params.port == 22
    assert state.connect_params.user == "root"
    assert state.ssh_module == FakeSSH
    assert state.ssh_connection_module == FakeSSH
  end

  test "real SSH backend module compiles and implements behaviour" do
    # Verify the actual module exists and exports the right functions
    assert {:module, SSH} = Code.ensure_loaded(SSH)
    assert function_exported?(SSH, :init, 1)
    assert function_exported?(SSH, :execute, 4)
    assert function_exported?(SSH, :cancel, 2)
    assert function_exported?(SSH, :terminate, 1)
    assert function_exported?(SSH, :cwd, 1)
    assert function_exported?(SSH, :cd, 2)
  end

  test "init validates required session and host/user config" do
    assert {:error, %Jido.Shell.Error{code: {:session, :invalid_state_transition}}} = SSH.init(%{})

    assert {:error, %Jido.Shell.Error{code: {:command, :start_failed}}} =
             SSH.init(%{session_pid: self(), user: "root", ssh_module: FakeSSH, ssh_connection_module: FakeSSH})

    assert {:error, %Jido.Shell.Error{code: {:command, :start_failed}}} =
             SSH.init(%{
               session_pid: self(),
               host: "   ",
               user: "root",
               ssh_module: FakeSSH,
               ssh_connection_module: FakeSSH
             })

    assert {:error, %Jido.Shell.Error{code: {:command, :start_failed}}} =
             SSH.init(%{
               session_pid: self(),
               host: "test-host",
               ssh_module: FakeSSH,
               ssh_connection_module: FakeSSH
             })
  end

  test "init builds key and password auth options" do
    pem = rsa_private_key_pem()
    path = Path.join(System.tmp_dir!(), "jido_shell_test_key_#{System.unique_integer([:positive])}.pem")
    File.write!(path, pem)

    on_exit(fn -> File.rm(path) end)

    {:ok, _state} = init_fake(%{key: pem})
    assert_receive {:fake_ssh, {:connect, _, _, opts_with_key, _}}
    assert [{:key_cb, {Jido.Shell.Backend.SSH.KeyCallback, [key: ^pem]}}] = Keyword.take(opts_with_key, [:key_cb])

    {:ok, _state} = init_fake(%{key_path: path})
    assert_receive {:fake_ssh, {:connect, _, _, opts_with_key_path, _}}
    assert [{:key_cb, {Jido.Shell.Backend.SSH.KeyCallback, [key: ^pem]}}] = Keyword.take(opts_with_key_path, [:key_cb])

    {:ok, _state} = init_fake(%{password: "secret"})
    assert_receive {:fake_ssh, {:connect, _, _, opts_with_password, _}}
    assert [password: ~c"secret"] = Keyword.take(opts_with_password, [:password])
  end

  test "init returns start_failed when key_path cannot be read or connect fails" do
    missing = Path.join(System.tmp_dir!(), "missing_#{System.unique_integer([:positive])}.pem")

    assert {:error, %Jido.Shell.Error{code: {:command, :start_failed}} = error} =
             init_fake(%{key_path: missing})

    assert error.context.reason == {:key_read_failed, :enoent}

    set_fake_mode(:connect_error)

    assert {:error, %Jido.Shell.Error{code: {:command, :start_failed}} = error} =
             init_fake()

    assert error.context.reason == {:ssh_connect, :econnrefused}
  end

  test "execute reconnects when existing connection pid is dead" do
    {:ok, state} = init_fake()

    assert_receive {:fake_ssh, {:connect, _, _, _, old_conn}}
    Process.exit(old_conn, :kill)

    {:ok, _worker_pid, _updated_state} = SSH.execute(%{state | conn: old_conn}, "echo ssh", [], [])

    assert_receive {:fake_ssh, {:connect, _, _, _, new_conn}}
    assert old_conn != new_conn
    assert_receive {:command_finished, {:ok, nil}}
  end

  test "execute reconnects when conn value is not a pid" do
    {:ok, state} = init_fake()
    {:ok, _worker_pid, _updated_state} = SSH.execute(%{state | conn: :invalid_conn}, "echo ssh", [], [])
    assert_receive {:fake_ssh, {:connect, _, _, _, _}}
    assert_receive {:command_finished, {:ok, nil}}
  end

  test "execute returns task start errors when task supervisor cannot accept children" do
    {:ok, full_supervisor} = Task.Supervisor.start_link(max_children: 0)
    {:ok, state} = init_fake(%{task_supervisor: full_supervisor})

    assert {:error, :max_children} = SSH.execute(state, "echo ssh", [], [])
  end

  test "execute reports start_failed for channel and exec setup errors" do
    {:ok, state} = init_fake()

    set_fake_mode(:session_channel_error)
    {:ok, _worker_pid, _state} = SSH.execute(state, "echo ssh", [], [])
    assert_receive {:command_finished, {:error, %Jido.Shell.Error{code: {:command, :start_failed}} = error}}
    assert error.context.reason == {:channel_open_failed, :session_channel_failed}

    set_fake_mode(:exec_failure)
    {:ok, _worker_pid, _state} = SSH.execute(state, "echo ssh", [], [])
    assert_receive {:fake_ssh, {:close_channel, _, _}}
    assert_receive {:command_finished, {:error, %Jido.Shell.Error{code: {:command, :start_failed}} = error}}
    assert error.context.reason == :exec_failed

    set_fake_mode(:exec_error)
    {:ok, _worker_pid, _state} = SSH.execute(state, "echo ssh", [], [])
    assert_receive {:fake_ssh, {:close_channel, _, _}}
    assert_receive {:command_finished, {:error, %Jido.Shell.Error{code: {:command, :start_failed}} = error}}
    assert error.context.reason == :exec_rejected
  end

  test "execute reports crashed when session channel raises" do
    {:ok, state} = init_fake()
    set_fake_mode(:session_channel_raise)

    {:ok, _worker_pid, _state} = SSH.execute(state, "echo ssh", [], [])

    assert_receive {:command_finished, {:error, %Jido.Shell.Error{code: {:command, :crashed}}}}
  end

  test "execute reads runtime/output limits from execution_context and normalizes env/args" do
    {:ok, state} = init_fake(%{env: %{"PERSIST" => "1"}})

    {:ok, _worker_pid, updated_state} =
      SSH.execute(
        state,
        "echo",
        ["ssh"],
        env: [ignored: :value],
        execution_context: %{limits: %{max_runtime_ms: 50, max_output_bytes: "64"}}
      )

    assert_receive {:fake_ssh, {:exec, _, _, wrapped_command}}
    assert wrapped_command =~ "echo ssh"
    assert updated_state.env == %{}
    assert_receive {:command_finished, {:ok, nil}}
  end

  test "execute handles non-map execution_context and invalid numeric limits" do
    {:ok, state} = init_fake()

    {:ok, _worker_pid, _updated_state} =
      SSH.execute(
        state,
        "echo ssh",
        [],
        execution_context: :invalid
      )

    assert_receive {:command_finished, {:ok, nil}}

    {:ok, _worker_pid, _updated_state} =
      SSH.execute(
        state,
        "echo ssh",
        [],
        execution_context: %{max_runtime_ms: "not-a-number"}
      )

    assert_receive {:command_finished, {:ok, nil}}
  end

  test "execute times out when channel emits no events" do
    {:ok, state} = init_fake()
    set_fake_mode(:no_events)

    {:ok, _worker_pid, _state} = SSH.execute(state, "echo ssh", [], timeout: 25)

    assert_receive {:fake_ssh, {:close_channel, _, _}}
    assert_receive {:command_finished, {:error, %Jido.Shell.Error{code: {:command, :timeout}}}}
  end

  test "cancel handles invalid refs and missing worker channel registrations" do
    {:ok, state} = init_fake()
    idle_worker = spawn(fn -> Process.sleep(200) end)

    assert :ok = SSH.cancel(state, idle_worker)
    assert {:error, :invalid_command_ref} = SSH.cancel(state, :not_a_pid)
  end

  test "cancel tolerates invalid commands table and terminate tolerates close/delete failures" do
    {:ok, state} = init_fake()
    idle_worker = spawn(fn -> Process.sleep(200) end)

    assert :ok = SSH.cancel(%{state | commands_table: :invalid_table}, idle_worker)

    set_fake_mode(:close_throw)
    assert :ok = SSH.terminate(%{state | commands_table: :invalid_table})
  end

  describe "Docker SSH integration" do
    @container_name "jido_shell_ssh_test"
    @ssh_port 2222
    @ssh_password "testpass"

    setup do
      ensure_container_running!()
      wait_for_sshd!("127.0.0.1", @ssh_port, 30_000)

      on_exit(fn -> cleanup_container() end)

      :ok
    end

    @tag :ssh_integration
    test "connects to Docker SSHD container and executes commands" do
      {:ok, state} =
        SSH.init(%{
          session_pid: self(),
          host: "127.0.0.1",
          port: @ssh_port,
          user: "root",
          password: @ssh_password
        })

      # Test basic echo
      {:ok, _worker, state} = SSH.execute(state, "echo hello-docker", [], [])
      assert_receive {:command_event, {:output, output}}, 10_000
      assert output =~ "hello-docker"
      assert_receive {:command_finished, {:ok, nil}}, 10_000

      # Test non-zero exit code
      {:ok, _worker, state} = SSH.execute(state, "exit 42", [], [])
      assert_receive {:command_finished, {:error, %Jido.Shell.Error{code: {:command, :exit_code}} = err}}, 10_000
      assert err.context.code == 42

      # Test cd / cwd tracking
      {:ok, _worker, state} = SSH.execute(state, "pwd", [], dir: "/tmp")
      assert_receive {:command_event, {:output, pwd_output}}, 10_000
      assert String.trim(pwd_output) == "/tmp"
      assert_receive {:command_finished, {:ok, nil}}, 10_000
      assert state.cwd == "/tmp"

      assert :ok = SSH.terminate(state)
    end

    @tag :ssh_integration
    test "handles output limit enforcement against real SSH" do
      {:ok, state} =
        SSH.init(%{
          session_pid: self(),
          host: "127.0.0.1",
          port: @ssh_port,
          user: "root",
          password: @ssh_password
        })

      # Generate output larger than the limit
      {:ok, _worker, _state} =
        SSH.execute(state, "dd if=/dev/zero bs=1024 count=10 2>/dev/null | base64", [], output_limit: 100)

      assert_receive {:command_finished, {:error, %Jido.Shell.Error{code: {:command, :output_limit_exceeded}}}}, 10_000

      assert :ok = SSH.terminate(state)
    end

    defp ensure_container_running! do
      # Stop any existing container
      System.cmd("docker", ["rm", "-f", @container_name], stderr_to_stdout: true)

      # Start an Alpine container with SSHD and password auth
      {_, 0} =
        System.cmd(
          "docker",
          [
            "run",
            "-d",
            "--name",
            @container_name,
            "-p",
            "#{@ssh_port}:22",
            "alpine:latest",
            "sh",
            "-c",
            Enum.join(
              [
                "apk add --no-cache openssh",
                "echo 'root:#{@ssh_password}' | chpasswd",
                "ssh-keygen -A",
                "sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config",
                "sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config",
                "/usr/sbin/sshd -D -e"
              ],
              " && "
            )
          ],
          stderr_to_stdout: true
        )
    end

    defp cleanup_container do
      System.cmd("docker", ["rm", "-f", @container_name], stderr_to_stdout: true)
    end

    defp wait_for_sshd!(host, port, timeout) do
      deadline = System.monotonic_time(:millisecond) + timeout
      do_wait_for_sshd(host, port, deadline)
    end

    defp do_wait_for_sshd(host, port, deadline) do
      if System.monotonic_time(:millisecond) > deadline do
        raise "Timed out waiting for SSHD on #{host}:#{port}"
      end

      # Try an actual SSH connection, not just TCP — SSHD needs time after port opens
      case :ssh.connect(
             String.to_charlist(host),
             port,
             [
               {:user, ~c"root"},
               {:password, ~c"testpass"},
               {:silently_accept_hosts, true},
               {:user_interaction, false}
             ],
             3_000
           ) do
        {:ok, conn} ->
          :ssh.close(conn)

        {:error, _} ->
          Process.sleep(1_000)
          do_wait_for_sshd(host, port, deadline)
      end
    end
  end
end
