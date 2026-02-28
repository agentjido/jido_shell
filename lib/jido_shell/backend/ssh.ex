defmodule Jido.Shell.Backend.SSH do
  @moduledoc """
  SSH backend implementation for remote command execution on any SSH-accessible machine.

  Uses Erlang's built-in `:ssh` module — zero additional dependencies.

  This backend keeps the same session event contract as other backends:

  - `{:output, chunk}`
  - `:command_done`
  - `{:error, %Jido.Shell.Error{}}`

  ## Configuration

      %{
        session_pid: pid(),             # required (injected by ShellSessionServer)
        host: String.t(),               # required
        port: pos_integer(),            # default 22
        user: String.t(),               # required
        key: binary(),                  # raw PEM content, OR
        key_path: String.t(),           # path to key file, OR
        password: String.t(),           # password auth
        cwd: String.t(),                # default "/"
        env: map(),                     # default %{}
        shell: String.t(),              # default "sh"
        connect_timeout: pos_integer(), # default 10_000
        ssh_module: module(),           # default :ssh (for testing)
        ssh_connection_module: module() # default :ssh_connection (for testing)
      }

  """

  @behaviour Jido.Shell.Backend

  alias Jido.Shell.Backend.OutputLimiter
  alias Jido.Shell.Error

  @default_task_supervisor Jido.Shell.CommandTaskSupervisor
  @default_shell "sh"
  @default_port 22
  @default_connect_timeout 10_000

  @impl true
  def init(config) when is_map(config) do
    ssh_mod = Map.get(config, :ssh_module, :ssh)
    ssh_conn_mod = Map.get(config, :ssh_connection_module, :ssh_connection)

    with {:ok, session_pid} <- fetch_session_pid(config),
         {:ok, host} <- fetch_required_string(config, :host),
         {:ok, user} <- fetch_required_string(config, :user),
         {:ok, auth_opts} <- build_auth_opts(config),
         port = Map.get(config, :port, @default_port),
         {:ok, conn} <- connect(ssh_mod, host, port, user, auth_opts, config) do
      {:ok,
       %{
         session_pid: session_pid,
         task_supervisor: Map.get(config, :task_supervisor, @default_task_supervisor),
         conn: conn,
         host: host,
         port: port,
         user: user,
         cwd: Map.get(config, :cwd, "/"),
         env: normalize_env(Map.get(config, :env, %{})),
         shell: Map.get(config, :shell, @default_shell),
         commands_table: :ets.new(:jido_shell_ssh_commands, [:public, :set]),
         ssh_module: ssh_mod,
         ssh_connection_module: ssh_conn_mod,
         connect_params: %{
           host: host,
           port: port,
           user: user,
           auth_opts: auth_opts,
           config: config
         }
       }}
    end
  end

  @impl true
  def execute(state, command, args, exec_opts) when is_binary(command) and is_list(args) and is_list(exec_opts) do
    with {:ok, state} <- ensure_connected(state) do
      line = command_line(command, args)
      cwd = Keyword.get(exec_opts, :dir, state.cwd)
      env = Keyword.get(exec_opts, :env, state.env) |> normalize_env()

      timeout =
        Keyword.get(exec_opts, :timeout) ||
          extract_limit(Keyword.get(exec_opts, :execution_context, %{}), :max_runtime_ms)

      output_limit =
        Keyword.get(exec_opts, :output_limit) ||
          extract_limit(Keyword.get(exec_opts, :execution_context, %{}), :max_output_bytes)

      case start_worker(state, line, cwd, env, timeout, output_limit) do
        {:ok, worker_pid} ->
          {:ok, worker_pid, %{state | cwd: cwd, env: env}}

        {:error, _} = error ->
          error
      end
    end
  end

  @impl true
  def cancel(state, command_ref) when is_pid(command_ref) do
    close_channel(state, command_ref)

    if Process.alive?(command_ref) do
      Process.exit(command_ref, :shutdown)
    end

    :ok
  end

  def cancel(_state, _command_ref), do: {:error, :invalid_command_ref}

  @impl true
  def terminate(state) do
    _ = safe_close_connection(state.ssh_module, state.conn)
    _ = maybe_delete_table(state.commands_table)
    :ok
  end

  @impl true
  def cwd(state), do: {:ok, state.cwd, state}

  @impl true
  def cd(state, path) when is_binary(path), do: {:ok, %{state | cwd: path}}

  # -- Private: Connection ---------------------------------------------------

  defp connect(ssh_mod, host, port, user, auth_opts, config) do
    timeout = Map.get(config, :connect_timeout, @default_connect_timeout)

    ssh_opts =
      [
        {:user, String.to_charlist(user)},
        {:silently_accept_hosts, true},
        {:user_interaction, false}
        | auth_opts
      ]

    case ssh_mod.connect(String.to_charlist(host), port, ssh_opts, timeout) do
      {:ok, conn} ->
        {:ok, conn}

      {:error, reason} ->
        {:error, Error.command(:start_failed, %{reason: {:ssh_connect, reason}, host: host, port: port})}
    end
  end

  defp ensure_connected(state) do
    if connection_alive?(state) do
      {:ok, state}
    else
      reconnect(state)
    end
  end

  defp connection_alive?(state) do
    Process.alive?(state.conn)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp reconnect(state) do
    %{host: host, port: port, user: user, auth_opts: auth_opts, config: config} =
      state.connect_params

    case connect(state.ssh_module, host, port, user, auth_opts, config) do
      {:ok, conn} ->
        {:ok, %{state | conn: conn}}

      {:error, _} = error ->
        error
    end
  end

  defp build_auth_opts(config) do
    cond do
      is_binary(Map.get(config, :key)) ->
        {:ok, [{:key_cb, {Jido.Shell.Backend.SSH.KeyCallback, key: Map.get(config, :key)}}]}

      is_binary(Map.get(config, :key_path)) ->
        path = Path.expand(Map.get(config, :key_path))

        case File.read(path) do
          {:ok, pem} ->
            {:ok, [{:key_cb, {Jido.Shell.Backend.SSH.KeyCallback, key: pem}}]}

          {:error, reason} ->
            {:error, Error.command(:start_failed, %{reason: {:key_read_failed, reason}, path: path})}
        end

      is_binary(Map.get(config, :password)) ->
        {:ok, [{:password, String.to_charlist(Map.get(config, :password))}]}

      true ->
        # Fall back to default SSH key discovery by the :ssh app
        {:ok, []}
    end
  end

  defp safe_close_connection(ssh_mod, conn) do
    ssh_mod.close(conn)
  catch
    _, _ -> :ok
  end

  # -- Private: Worker -------------------------------------------------------

  defp start_worker(state, line, cwd, env, timeout, output_limit) do
    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           run_command_worker(state, line, cwd, env, timeout, output_limit)
         end) do
      {:ok, worker_pid} -> {:ok, worker_pid}
      {:error, _} = error -> error
    end
  end

  defp run_command_worker(state, line, cwd, env, timeout, output_limit) do
    ssh_conn_mod = state.ssh_connection_module

    case open_channel_and_exec(state.conn, ssh_conn_mod, line, cwd, env, state.shell) do
      {:ok, channel_id} ->
        :ets.insert(state.commands_table, {self(), channel_id})
        await_ssh_events(state, channel_id, line, timeout, output_limit, 0)

      {:error, reason} ->
        send_finished(state.session_pid, {:error, Error.command(:start_failed, %{reason: reason, line: line})})
    end

    :ets.delete(state.commands_table, self())
  rescue
    error ->
      send_finished(
        state.session_pid,
        {:error, Error.command(:crashed, %{line: line, reason: Exception.message(error)})}
      )
  end

  defp open_channel_and_exec(conn, ssh_conn_mod, line, cwd, env, shell) do
    case ssh_conn_mod.session_channel(conn, :infinity) do
      {:ok, channel_id} ->
        # Set environment variables (best effort — many SSH servers restrict this)
        Enum.each(env, fn {k, v} ->
          ssh_conn_mod.setenv(conn, channel_id, String.to_charlist(k), String.to_charlist(v), 5_000)
        end)

        wrapped = remote_command(shell, line, cwd, env)

        case ssh_conn_mod.exec(conn, channel_id, String.to_charlist(wrapped), :infinity) do
          :success ->
            {:ok, channel_id}

          :failure ->
            ssh_conn_mod.close(conn, channel_id)
            {:error, :exec_failed}

          {:error, reason} ->
            ssh_conn_mod.close(conn, channel_id)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:channel_open_failed, reason}}
    end
  end

  defp await_ssh_events(state, channel_id, line, timeout, output_limit, emitted_bytes) do
    ssh_conn_mod = state.ssh_connection_module

    receive do
      {:ssh_cm, _conn, {:data, ^channel_id, _type, data}} ->
        chunk = IO.iodata_to_binary(data)

        case OutputLimiter.check(byte_size(chunk), emitted_bytes, output_limit) do
          {:ok, updated_total} ->
            send(state.session_pid, {:command_event, {:output, chunk}})
            await_ssh_events(state, channel_id, line, timeout, output_limit, updated_total)

          {:limit_exceeded, error} ->
            ssh_conn_mod.close(state.conn, channel_id)
            send_finished(state.session_pid, {:error, error})
        end

      {:ssh_cm, _conn, {:exit_status, ^channel_id, 0}} ->
        await_ssh_events(state, channel_id, line, timeout, output_limit, emitted_bytes)

      {:ssh_cm, _conn, {:exit_status, ^channel_id, code}} ->
        # Don't send finished yet — wait for :closed or :eof to ensure all data is flushed
        await_ssh_close(state, channel_id, line, code)

      {:ssh_cm, _conn, {:eof, ^channel_id}} ->
        await_ssh_events(state, channel_id, line, timeout, output_limit, emitted_bytes)

      {:ssh_cm, _conn, {:closed, ^channel_id}} ->
        send_finished(state.session_pid, {:ok, nil})
    after
      receive_timeout(timeout) ->
        ssh_conn_mod.close(state.conn, channel_id)
        send_finished(state.session_pid, {:error, Error.command(:timeout, %{line: line})})
    end
  end

  # After we've received a non-zero exit_status, drain remaining data/eof/closed messages
  defp await_ssh_close(state, channel_id, line, exit_code) do
    receive do
      {:ssh_cm, _conn, {:data, ^channel_id, _type, data}} ->
        chunk = IO.iodata_to_binary(data)
        send(state.session_pid, {:command_event, {:output, chunk}})
        await_ssh_close(state, channel_id, line, exit_code)

      {:ssh_cm, _conn, {:eof, ^channel_id}} ->
        await_ssh_close(state, channel_id, line, exit_code)

      {:ssh_cm, _conn, {:closed, ^channel_id}} ->
        send_finished(state.session_pid, {:error, Error.command(:exit_code, %{code: exit_code, line: line})})
    after
      5_000 ->
        send_finished(state.session_pid, {:error, Error.command(:exit_code, %{code: exit_code, line: line})})
    end
  end

  # -- Private: Channel cancellation -----------------------------------------

  defp close_channel(state, worker_pid) do
    do_close_channel(state, worker_pid, 5)
  rescue
    _ -> :ok
  end

  defp do_close_channel(_state, _worker_pid, 0), do: :ok

  defp do_close_channel(state, worker_pid, attempts_left) do
    case :ets.lookup(state.commands_table, worker_pid) do
      [{^worker_pid, channel_id}] ->
        state.ssh_connection_module.close(state.conn, channel_id)

      _ ->
        Process.sleep(10)
        do_close_channel(state, worker_pid, attempts_left - 1)
    end
  end

  # -- Private: Helpers ------------------------------------------------------

  defp command_line(command, []), do: command
  defp command_line(command, args), do: Enum.join([command | args], " ")

  defp remote_command(shell, line, cwd, env) do
    env_prefix =
      env
      |> Enum.map(fn {k, v} -> "#{k}=#{shell_escape(v)}" end)
      |> Enum.join(" ")

    case env_prefix do
      "" -> "cd #{shell_escape(cwd)} && #{shell} -lc #{shell_escape(line)}"
      prefix -> "cd #{shell_escape(cwd)} && env #{prefix} #{shell} -lc #{shell_escape(line)}"
    end
  end

  defp shell_escape(value) do
    # Use single-quote wrapping with internal single-quote escaping
    "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"
  end

  defp send_finished(session_pid, result) do
    send(session_pid, {:command_finished, result})
  end

  defp receive_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout
  defp receive_timeout(_timeout), do: 60_000

  defp normalize_env(env) when is_map(env) do
    Enum.reduce(env, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), to_string(value))
    end)
  end

  defp normalize_env(_env), do: %{}

  defp extract_limit(execution_context, key) when is_map(execution_context) do
    limits = Map.get(execution_context, :limits, %{})

    parse_limit(
      Map.get(limits, key, Map.get(execution_context, key, nil))
    )
  end

  defp extract_limit(_, _), do: nil

  defp parse_limit(value) when is_integer(value) and value > 0, do: value

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_limit(_), do: nil

  defp maybe_delete_table(table) do
    :ets.delete(table)
    :ok
  rescue
    _ -> :ok
  end

  defp fetch_session_pid(config) do
    case Map.get(config, :session_pid) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> {:error, Error.session(:invalid_state_transition, %{reason: :missing_session_pid})}
    end
  end

  defp fetch_required_string(config, key) do
    case Map.get(config, key) do
      value when is_binary(value) ->
        if byte_size(String.trim(value)) > 0 do
          {:ok, value}
        else
          {:error, Error.command(:start_failed, %{reason: {:missing_config, key}})}
        end

      _ ->
        {:error, Error.command(:start_failed, %{reason: {:missing_config, key}})}
    end
  end
end
