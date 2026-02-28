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

    def connect(host, port, _opts, _timeout) do
      conn = spawn(fn -> Process.sleep(:infinity) end)
      notify({:connect, host, port, conn})
      {:ok, conn}
    end

    def close(conn) do
      notify({:close, conn})
      :ok
    end

    # -- :ssh_connection API surface --

    def session_channel(conn, _timeout) do
      channel_id = :erlang.unique_integer([:positive])
      notify({:session_channel, conn, channel_id})
      {:ok, channel_id}
    end

    def setenv(_conn, _channel_id, _var, _value, _timeout), do: :success

    def exec(conn, channel_id, command, _timeout) do
      command_str = to_string(command)
      notify({:exec, conn, channel_id, command_str})

      caller = self()

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

    on_exit(fn ->
      :persistent_term.erase({FakeSSH, :test_pid})
    end)

    :ok
  end

  defp init_fake(overrides \\ %{}) do
    config = Map.merge(%{session_pid: self(), host: "test-host", user: "root"}, @fake_config)
    SSH.init(Map.merge(config, overrides))
  end

  test "init connects and terminate closes" do
    {:ok, state} = init_fake(%{port: 22})

    assert_receive {:fake_ssh, {:connect, ~c"test-host", 22, _conn}}
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

  test "execute enforces output limits" do
    {:ok, state} = init_fake()

    {:ok, _worker_pid, _state} = SSH.execute(state, "limit ssh", [], output_limit: 3)

    assert_receive {:command_finished,
                    {:error, %Jido.Shell.Error{code: {:command, :output_limit_exceeded}}}}
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
        System.cmd("docker", [
          "run", "-d",
          "--name", @container_name,
          "-p", "#{@ssh_port}:22",
          "alpine:latest",
          "sh", "-c",
          Enum.join([
            "apk add --no-cache openssh",
            "echo 'root:#{@ssh_password}' | chpasswd",
            "ssh-keygen -A",
            "sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config",
            "sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config",
            "/usr/sbin/sshd -D -e"
          ], " && ")
        ], stderr_to_stdout: true)
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
      case :ssh.connect(String.to_charlist(host), port, [
             {:user, ~c"root"},
             {:password, ~c"testpass"},
             {:silently_accept_hosts, true},
             {:user_interaction, false}
           ], 3_000) do
        {:ok, conn} ->
          :ssh.close(conn)

        {:error, _} ->
          Process.sleep(1_000)
          do_wait_for_sshd(host, port, deadline)
      end
    end
  end
end
