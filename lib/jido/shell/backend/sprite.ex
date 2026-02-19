defmodule Jido.Shell.Backend.Sprite do
  @moduledoc """
  Sprite backend implementation for remote command execution on Fly.io Sprites.

  This backend keeps the same session event contract as the local backend:

  - `{:output, chunk}`
  - `:command_done`
  - `{:error, %Jido.Shell.Error{}}`
  """

  @behaviour Jido.Shell.Backend

  alias Jido.Shell.Error

  @default_task_supervisor Jido.Shell.CommandTaskSupervisor
  @default_shell "sh"

  @impl true
  def init(config) when is_map(config) do
    with {:ok, session_pid} <- fetch_session_pid(config),
         {:ok, sprite_name} <- fetch_required(config, :sprite_name),
         {:ok, token} <- fetch_required(config, :token),
         sprites_module <- Map.get(config, :sprites_module, Sprites),
         {:ok, client} <- build_client(sprites_module, token, Map.get(config, :base_url)),
         {:ok, sprite, owns_sprite?} <-
           connect_sprite(
             sprites_module,
             client,
             sprite_name,
             Map.get(config, :create, false)
           ) do
      {:ok,
       %{
         sprites_module: sprites_module,
         session_pid: session_pid,
         task_supervisor: Map.get(config, :task_supervisor, @default_task_supervisor),
         client: client,
         sprite: sprite,
         sprite_name: sprite_name,
         owns_sprite?: owns_sprite?,
         cwd: Map.get(config, :cwd, "/"),
         env: normalize_env(Map.get(config, :env, %{})),
         shell: Map.get(config, :shell, @default_shell),
         network_policy: nil,
         commands_table: :ets.new(:jido_shell_sprite_commands, [:public, :set])
       }}
    end
  end

  @impl true
  def execute(state, command, args, exec_opts) when is_binary(command) and is_list(args) and is_list(exec_opts) do
    line = command_line(command, args)
    cwd = Keyword.get(exec_opts, :dir, state.cwd)
    env = Keyword.get(exec_opts, :env, state.env) |> normalize_env()
    execution_context = normalize_map(Keyword.get(exec_opts, :execution_context, %{}))

    timeout =
      Keyword.get(exec_opts, :timeout) ||
        extract_limit(execution_context, :max_runtime_ms)

    output_limit =
      Keyword.get(exec_opts, :output_limit) ||
        extract_limit(execution_context, :max_output_bytes)

    with {:ok, state} <- maybe_configure_network(state, execution_context),
         {:ok, worker_pid} <- start_worker(state, line, cwd, env, timeout, output_limit) do
      {:ok, worker_pid, %{state | cwd: cwd, env: env}}
    end
  end

  @impl true
  def cancel(state, command_ref) when is_pid(command_ref) do
    close_remote_command(state, command_ref)

    if Process.alive?(command_ref) do
      Process.exit(command_ref, :shutdown)
    end

    :ok
  end

  def cancel(_state, _command_ref), do: {:error, :invalid_command_ref}

  @impl true
  def terminate(state) do
    _ = maybe_destroy_sprite(state)
    _ = maybe_delete_table(state.commands_table)
    :ok
  end

  @impl true
  def cwd(state), do: {:ok, state.cwd, state}

  @impl true
  def cd(state, path) when is_binary(path), do: {:ok, %{state | cwd: path}}

  @impl true
  def configure_network(state, policy) when is_map(policy) do
    mapped_policy = map_network_policy(policy)

    case invoke_any(state.sprites_module, [
           {:set_network_policy, [state.sprite, mapped_policy]},
           {:set_network_policy, [state.client, state.sprite, mapped_policy]},
           {:update_network_policy, [state.sprite, mapped_policy]},
           {:update_network_policy, [state.client, state.sprite, mapped_policy]},
           {:configure_network, [state.sprite, mapped_policy]},
           {:configure_network, [state.client, state.sprite, mapped_policy]},
           {:network_policy, [state.sprite, mapped_policy]},
           {:network_policy, [state.client, state.sprite, mapped_policy]}
         ]) do
      {:ok, _} ->
        {:ok, %{state | network_policy: mapped_policy}}

      {:error, :unsupported} ->
        # Some SDK versions may not expose policy APIs.
        {:ok, %{state | network_policy: mapped_policy}}

      {:error, reason} ->
        {:error, Error.command(:network_policy_failed, %{reason: reason})}
    end
  end

  defp fetch_session_pid(config) do
    case Map.get(config, :session_pid) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> {:error, Error.session(:invalid_state_transition, %{reason: :missing_session_pid})}
    end
  end

  defp fetch_required(config, key) do
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

  defp build_client(sprites_module, token, base_url) do
    opts = if is_binary(base_url) and String.trim(base_url) != "", do: [base_url: base_url], else: []

    invoke_any(sprites_module, [
      {:client, [token, opts]},
      {:client, [[token: token] ++ opts]},
      {:client, [token]},
      {:new, [token, opts]},
      {:new, [[token: token] ++ opts]},
      {:new, [token]}
    ])
  end

  defp connect_sprite(sprites_module, client, sprite_name, true) do
    case invoke_any(sprites_module, [
           {:create, [client, sprite_name]},
           {:create, [client, sprite_name, []]}
         ]) do
      {:ok, sprite} -> {:ok, sprite, true}
      {:error, reason} -> {:error, Error.command(:start_failed, %{reason: reason})}
    end
  end

  defp connect_sprite(sprites_module, client, sprite_name, false) do
    case invoke_any(sprites_module, [
           {:sprite, [client, sprite_name]},
           {:sprite, [client, sprite_name, []]},
           {:get, [client, sprite_name]}
         ]) do
      {:ok, sprite} -> {:ok, sprite, false}
      {:error, reason} -> {:error, Error.command(:start_failed, %{reason: reason})}
    end
  end

  defp maybe_destroy_sprite(%{owns_sprite?: false}), do: :ok

  defp maybe_destroy_sprite(state) do
    case invoke_any(state.sprites_module, [
           {:destroy, [state.sprite]},
           {:destroy, [state.client, state.sprite]},
           {:destroy, [state.client, state.sprite_name]}
         ]) do
      {:ok, _} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp maybe_delete_table(table) do
    :ets.delete(table)
    :ok
  rescue
    _ -> :ok
  end

  defp maybe_configure_network(state, execution_context) do
    case extract_network_policy(execution_context) do
      nil ->
        {:ok, state}

      policy when policy == state.network_policy ->
        {:ok, state}

      policy ->
        configure_network(state, policy)
    end
  end

  defp extract_network_policy(execution_context) do
    case get_opt(execution_context, :network, nil) do
      nil ->
        nil

      network ->
        %{
          default: normalize_default(get_opt(network, :default, :deny)),
          allow_domains: normalize_string_list(get_opt(network, :allow_domains, [])),
          block_domains: normalize_string_list(get_opt(network, :block_domains, [])),
          allow_ports: normalize_port_list(get_opt(network, :allow_ports, [])),
          block_ports: normalize_port_list(get_opt(network, :block_ports, []))
        }
    end
  end

  defp map_network_policy(policy) do
    %{
      default: normalize_default(get_opt(policy, :default, :deny)),
      allow_domains: normalize_string_list(get_opt(policy, :allow_domains, [])),
      block_domains: normalize_string_list(get_opt(policy, :block_domains, [])),
      allow_ports: normalize_port_list(get_opt(policy, :allow_ports, [])),
      block_ports: normalize_port_list(get_opt(policy, :block_ports, []))
    }
  end

  defp normalize_default(:allow), do: :allow
  defp normalize_default("allow"), do: :allow
  defp normalize_default(_), do: :deny

  defp start_worker(state, line, cwd, env, timeout, output_limit) do
    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           run_command_worker(state, line, cwd, env, timeout, output_limit)
         end) do
      {:ok, worker_pid} -> {:ok, worker_pid}
      {:error, _} = error -> error
    end
  end

  defp run_command_worker(state, line, cwd, env, timeout, output_limit) do
    case spawn_remote_command(state, line, cwd, env, timeout) do
      {:ok, cmd_ref} ->
        :ets.insert(state.commands_table, {self(), cmd_ref})

        await_stream_events(state, cmd_ref, line, timeout, output_limit, 0)

      {:error, :unsupported} ->
        run_sync_command(state, line, cwd, env, timeout, output_limit)

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

  defp spawn_remote_command(state, line, cwd, env, timeout) do
    {remote_cmd, remote_args} = remote_command(state.shell, line)
    opts = spawn_opts(cwd, env, timeout)

    invoke_any(state.sprites_module, [
      {:spawn, [state.sprite, remote_cmd, remote_args, opts]},
      {:spawn, [state.sprite, remote_cmd, remote_args]},
      {:spawn, [state.client, state.sprite, remote_cmd, remote_args, opts]},
      {:spawn, [state.client, state.sprite, remote_cmd, remote_args]}
    ])
  end

  defp run_sync_command(state, line, cwd, env, timeout, output_limit) do
    {remote_cmd, remote_args} = remote_command(state.shell, line)
    opts = spawn_opts(cwd, env, timeout)

    case invoke_any(state.sprites_module, [
           {:cmd, [state.sprite, remote_cmd, remote_args, opts]},
           {:cmd, [state.sprite, remote_cmd, remote_args]},
           {:cmd, [state.client, state.sprite, remote_cmd, remote_args, opts]},
           {:cmd, [state.client, state.sprite, remote_cmd, remote_args]}
         ]) do
      {:ok, result} ->
        case parse_cmd_result(result) do
          {:ok, output, 0} ->
            with :ok <- maybe_emit_output(state.session_pid, output, output_limit) do
              send_finished(state.session_pid, {:ok, nil})
            else
              {:error, %Error{} = error} ->
                send_finished(state.session_pid, {:error, error})
            end

          {:ok, output, code} ->
            _ = maybe_emit_output(state.session_pid, output, output_limit)
            send_finished(state.session_pid, {:error, Error.command(:exit_code, %{code: code, line: line})})

          {:error, reason} ->
            send_finished(state.session_pid, {:error, Error.command(:start_failed, %{reason: reason, line: line})})
        end

      {:error, reason} ->
        send_finished(state.session_pid, {:error, Error.command(:start_failed, %{reason: reason, line: line})})
    end
  end

  defp await_stream_events(state, cmd_ref, line, timeout, output_limit, emitted_bytes) do
    receive do
      {:stdout, _command, data} ->
        case emit_stream_chunk(state, cmd_ref, data, output_limit, emitted_bytes) do
          {:ok, updated_bytes} ->
            await_stream_events(state, cmd_ref, line, timeout, output_limit, updated_bytes)

          {:error, %Error{} = error} ->
            send_finished(state.session_pid, {:error, error})
        end

      {:stderr, _command, data} ->
        case emit_stream_chunk(state, cmd_ref, data, output_limit, emitted_bytes) do
          {:ok, updated_bytes} ->
            await_stream_events(state, cmd_ref, line, timeout, output_limit, updated_bytes)

          {:error, %Error{} = error} ->
            send_finished(state.session_pid, {:error, error})
        end

      {:exit, _command, 0} ->
        send_finished(state.session_pid, {:ok, nil})

      {:exit, _command, code} ->
        send_finished(state.session_pid, {:error, Error.command(:exit_code, %{code: code, line: line})})

      {:error, _command, reason} when reason in [:closed, :normal] ->
        send_finished(state.session_pid, {:ok, nil})

      {:error, _command, reason} ->
        send_finished(
          state.session_pid,
          {:error, Error.command(:start_failed, %{reason: reason, line: line})}
        )
    after
      receive_timeout(timeout) ->
        _ = close_remote_handle(state, cmd_ref)
        send_finished(state.session_pid, {:error, Error.command(:timeout, %{line: line})})
    end
  end

  defp emit_stream_chunk(state, cmd_ref, data, output_limit, emitted_bytes) do
    chunk = IO.iodata_to_binary(data)
    chunk_bytes = byte_size(chunk)
    updated_total = emitted_bytes + chunk_bytes

    cond do
      is_integer(output_limit) and output_limit > 0 and updated_total > output_limit ->
        _ = close_remote_handle(state, cmd_ref)

        {:error,
         Error.command(:output_limit_exceeded, %{
           emitted_bytes: updated_total,
           max_output_bytes: output_limit
         })}

      true ->
        send(state.session_pid, {:command_event, {:output, chunk}})
        {:ok, updated_total}
    end
  end

  defp maybe_emit_output(_session_pid, nil, _output_limit), do: :ok
  defp maybe_emit_output(_session_pid, "", _output_limit), do: :ok

  defp maybe_emit_output(session_pid, output, output_limit) do
    chunk = IO.iodata_to_binary(output)
    chunk_bytes = byte_size(chunk)

    if is_integer(output_limit) and output_limit > 0 and chunk_bytes > output_limit do
      {:error,
       Error.command(:output_limit_exceeded, %{
         emitted_bytes: chunk_bytes,
         max_output_bytes: output_limit
       })}
    else
      send(session_pid, {:command_event, {:output, chunk}})
      :ok
    end
  end

  defp parse_cmd_result({output, code}) when is_integer(code), do: {:ok, output, code}

  defp parse_cmd_result(%{output: output, exit_code: code}) when is_integer(code) do
    {:ok, output, code}
  end

  defp parse_cmd_result(%{stdout: stdout, status: code}) when is_integer(code), do: {:ok, stdout, code}
  defp parse_cmd_result(other), do: {:error, {:unexpected_cmd_result, other}}

  defp close_remote_command(state, worker_pid) do
    do_close_remote_command(state, worker_pid, 5)
  rescue
    _ -> :ok
  end

  defp do_close_remote_command(_state, _worker_pid, 0), do: :ok

  defp do_close_remote_command(state, worker_pid, attempts_left) do
    case :ets.lookup(state.commands_table, worker_pid) do
      [{^worker_pid, cmd_ref}] ->
        close_remote_handle(state, cmd_ref)

      _ ->
        Process.sleep(10)
        do_close_remote_command(state, worker_pid, attempts_left - 1)
    end
  end

  defp close_remote_handle(state, cmd_ref) do
    _ = invoke_any(state.sprites_module, [{:close_stdin, [cmd_ref]}])
    _ = invoke_any(state.sprites_module, [{:kill, [cmd_ref]}])
    :ok
  end

  defp command_line(command, []), do: command
  defp command_line(command, args), do: Enum.join([command | args], " ")

  defp remote_command(shell, line), do: {shell, ["-lc", line]}

  defp spawn_opts(cwd, env, timeout) do
    []
    |> Keyword.put(:dir, cwd)
    |> Keyword.put(:env, env_to_tuples(env))
    |> maybe_put(:timeout, timeout)
    |> Keyword.put(:stderr_to_stdout, false)
  end

  defp env_to_tuples(env) when is_map(env), do: Enum.to_list(env)
  defp env_to_tuples(env) when is_list(env), do: env
  defp env_to_tuples(_), do: []

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

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

  defp normalize_map(value) when is_map(value), do: value

  defp normalize_map(value) when is_list(value) do
    if Keyword.keyword?(value) do
      Enum.into(value, %{}, fn {key, val} -> {key, normalize_map(val)} end)
    else
      value
    end
  end

  defp normalize_map(value), do: value

  defp extract_limit(execution_context, key) do
    limits = get_opt(execution_context, :limits, %{})
    parse_limit(get_opt(limits, key, get_opt(execution_context, key, nil)))
  end

  defp parse_limit(value) when is_integer(value) and value > 0, do: value

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_limit(_), do: nil

  defp normalize_string_list(value) do
    value
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_port_list(value) do
    value
    |> List.wrap()
    |> Enum.reduce([], fn port, acc ->
      case parse_port(port) do
        nil -> acc
        parsed -> [parsed | acc]
      end
    end)
    |> Enum.uniq()
    |> Enum.reverse()
  end

  defp parse_port(port) when is_integer(port) and port >= 0 and port <= 65_535, do: port

  defp parse_port(port) when is_binary(port) do
    case Integer.parse(port) do
      {parsed, ""} when parsed >= 0 and parsed <= 65_535 -> parsed
      _ -> nil
    end
  end

  defp parse_port(_), do: nil

  defp get_opt(source, key, default) when is_map(source) do
    case Map.fetch(source, key) do
      {:ok, value} -> value
      :error -> Map.get(source, to_string(key), default)
    end
  end

  defp get_opt(source, key, default) when is_list(source) do
    if Keyword.keyword?(source) do
      case Keyword.fetch(source, key) do
        {:ok, value} -> value
        :error -> Keyword.get(source, to_string(key), default)
      end
    else
      default
    end
  end

  defp get_opt(_source, _key, default), do: default

  defp invoke_any(module, candidates) do
    case Code.ensure_loaded(module) do
      {:module, _} -> do_invoke_any(module, candidates, :unsupported)
      {:error, _} -> {:error, :unsupported}
    end
  end

  defp do_invoke_any(_module, [], last_error), do: {:error, last_error}

  defp do_invoke_any(module, [{fun, args} | rest], _last_error) do
    if function_exported?(module, fun, length(args)) do
      case safe_apply(module, fun, args) do
        {:ok, _} = ok -> ok
        {:error, reason} -> do_invoke_any(module, rest, reason)
      end
    else
      do_invoke_any(module, rest, :unsupported)
    end
  end

  defp safe_apply(module, fun, args) do
    result = apply(module, fun, args)

    case result do
      {:ok, _} = ok -> ok
      {:error, _} = error -> error
      other -> {:ok, other}
    end
  rescue
    error ->
      {:error, {:exception, Exception.message(error)}}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end
end
