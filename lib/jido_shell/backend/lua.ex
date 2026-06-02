defmodule Jido.Shell.Backend.Lua do
  @moduledoc """
  Backend that executes Lua scripts in the pure-Elixir `:lua` VM.

  The VM is sandboxed by `Lua.new/0`: host file I/O, OS execution, `require`,
  and dynamic file loading are disabled. Registered Jido shell commands are
  exposed under the `jido.*` namespace and route through
  `Jido.Shell.CommandRunner`.
  """

  @behaviour Jido.Shell.Backend

  alias Jido.Shell.Backend.Lua.JidoApi
  alias Jido.Shell.Backend.Lua.Session
  alias Jido.Shell.Backend.OutputLimiter
  alias Jido.Shell.Error

  @default_task_supervisor Jido.Shell.CommandTaskSupervisor
  @eval_start_timeout 5_000

  @impl true
  def init(config) when is_map(config) do
    persistent = Map.get(config, :persistent, true)

    with :ok <- ensure_dep_available(),
         {:ok, session_pid} <- fetch_session_pid(config),
         workspace_id <- Map.get(config, :workspace_id, ""),
         {:ok, lua_session} <- maybe_start_lua_session(persistent, workspace_id) do
      {:ok,
       %{
         lua_session: lua_session,
         session_id: Map.get(config, :session_id, "lua-session"),
         session_pid: session_pid,
         task_supervisor: Map.get(config, :task_supervisor, @default_task_supervisor),
         workspace_id: workspace_id,
         cwd: Map.get(config, :cwd, "/"),
         env: Map.get(config, :env, %{}),
         max_heap_size: Map.get(config, :max_heap_size),
         persistent: persistent
       }}
    end
  end

  @impl true
  def execute(state, command, args, exec_opts) when is_binary(command) and is_list(args) and is_list(exec_opts) do
    line = command_line(command, args)
    timeout = positive_limit(Keyword.get(exec_opts, :timeout))
    output_limit = positive_limit(Keyword.get(exec_opts, :output_limit))
    ref = make_ref()
    limit_ref = make_ref()

    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           await_eval(ref, limit_ref, state.session_pid, line, timeout)
         end) do
      {:ok, watcher_pid} ->
        emit = limited_emit(state.session_pid, watcher_pid, limit_ref, output_limit)
        context = eval_context(state, exec_opts, emit)

        eval_pid =
          if state.persistent == false do
            spawn_eval_worker_stateless(
              watcher_pid,
              ref,
              state.workspace_id,
              line,
              context,
              Map.get(state, :max_heap_size)
            )
          else
            spawn_eval_worker(watcher_pid, ref, state.lua_session, line, context, Map.get(state, :max_heap_size))
          end

        send(watcher_pid, {ref, :eval_pid, eval_pid})

        {:ok, %{monitor_pid: watcher_pid, watcher_pid: watcher_pid, eval_pid: eval_pid}, state}

      {:error, reason} ->
        {:error, Error.command(:start_failed, %{reason: reason, line: line})}
    end
  end

  @impl true
  def cancel(_state, %{eval_pid: eval_pid, watcher_pid: watcher_pid}) do
    kill_process(eval_pid, :kill)
    kill_process(watcher_pid, :shutdown)
    :ok
  end

  def cancel(_state, _command_ref), do: {:error, :invalid_command_ref}

  @impl true
  def terminate(state) do
    case Map.get(state, :lua_session) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: Session.stop(pid)
        :ok

      _ ->
        :ok
    end
  end

  @impl true
  def cwd(state), do: {:ok, state.cwd, state}

  @impl true
  def cd(state, path) when is_binary(path), do: {:ok, %{state | cwd: path}}

  @impl true
  def configure_network(state, _policy), do: {:ok, state}

  defp ensure_dep_available do
    if Code.ensure_loaded?(Lua) and Code.ensure_loaded?(Lua.API) do
      :ok
    else
      {:error, Error.command(:start_failed, %{reason: :lua_dep_unavailable})}
    end
  end

  defp fetch_session_pid(config) do
    case Map.get(config, :session_pid) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> {:error, Error.session(:invalid_state_transition, %{reason: :missing_session_pid})}
    end
  end

  defp maybe_start_lua_session(false, _workspace_id), do: {:ok, nil}
  defp maybe_start_lua_session(_persistent, workspace_id), do: start_lua_session(workspace_id)

  defp start_lua_session(workspace_id) do
    lua =
      Lua.new()
      |> Lua.load_api(JidoApi)
      |> JidoApi.install_globals()
      |> Lua.set!([:JIDO_WORKSPACE_ID], workspace_id)

    Session.new(lua)
  rescue
    error -> {:error, Error.command(:start_failed, %{reason: Exception.message(error)})}
  end

  defp command_line(command, []), do: command
  defp command_line(command, args), do: Enum.join([command | args], " ")

  defp eval_context(state, exec_opts, emit) do
    %{
      session_id: Map.get(state, :session_id, "lua-session"),
      workspace_id: state.workspace_id,
      cwd: Map.get(state, :cwd, "/"),
      env: Map.get(state, :env, %{}),
      execution_context: Keyword.get(exec_opts, :execution_context, %{}),
      emit: emit
    }
  end

  defp spawn_eval_worker(watcher_pid, ref, lua_session, line, context, max_heap_size) do
    :erlang.spawn_opt(
      fn ->
        result = Session.eval(lua_session, line, context)
        send(watcher_pid, {ref, {:done, result}})
      end,
      spawn_opts(max_heap_size)
    )
  end

  defp spawn_eval_worker_stateless(watcher_pid, ref, workspace_id, line, context, max_heap_size) do
    :erlang.spawn_opt(
      fn ->
        result = eval_stateless(workspace_id, line, context)
        send(watcher_pid, {ref, {:done, result}})
      end,
      spawn_opts(max_heap_size)
    )
  end

  defp eval_stateless(workspace_id, script, context) do
    lua =
      Lua.new()
      |> Lua.load_api(JidoApi)
      |> JidoApi.install_globals()
      |> Lua.set!([:JIDO_WORKSPACE_ID], workspace_id)
      |> Lua.put_private(JidoApi.context_key(), context)

    {_return, new_lua} = Lua.eval!(lua, script)

    final_context =
      case Lua.get_private(new_lua, JidoApi.context_key()) do
        {:ok, ctx} when is_map(ctx) -> ctx
        _ -> context
      end

    {:ok, extract_state_update(context, final_context)}
  rescue
    error in [Lua.CompilerException] ->
      {:error, Error.command(:syntax_error, %{line: script, reason: Exception.message(error)})}

    error in [Lua.RuntimeException] ->
      {:error, Error.command(:runtime_error, %{line: script, reason: Exception.message(error)})}

    error ->
      {:error, Error.command(:crashed, %{line: script, reason: Exception.message(error)})}
  catch
    :throw, {:lua_output_limit_exceeded, %Error{} = error} ->
      {:error, error}

    kind, reason ->
      {:error, Error.command(:crashed, %{line: script, reason: {kind, reason}})}
  end

  defp extract_state_update(initial, final) do
    changes =
      %{}
      |> maybe_change(:cwd, Map.get(initial, :cwd), Map.get(final, :cwd))
      |> maybe_change(:env, Map.get(initial, :env), Map.get(final, :env))

    if map_size(changes) == 0, do: nil, else: {:state_update, changes}
  end

  defp maybe_change(changes, _key, same, same), do: changes
  defp maybe_change(changes, key, _old, new_val), do: Map.put(changes, key, new_val)

  defp spawn_opts(max_heap_size) when is_integer(max_heap_size) and max_heap_size > 0 do
    [{:max_heap_size, max_heap_size}]
  end

  defp spawn_opts(_max_heap_size), do: []

  defp await_eval(ref, limit_ref, session_pid, line, timeout) do
    receive do
      {^ref, :eval_pid, eval_pid} when is_pid(eval_pid) ->
        monitor_ref = Process.monitor(eval_pid)
        await_eval_result(ref, limit_ref, monitor_ref, eval_pid, session_pid, line, timeout)
    after
      @eval_start_timeout ->
        finish(session_pid, {:error, Error.command(:start_failed, %{reason: :eval_worker_not_started, line: line})})
    end
  end

  defp await_eval_result(ref, limit_ref, monitor_ref, eval_pid, session_pid, line, timeout) do
    receive do
      {^limit_ref, {:error, %Error{} = error}} ->
        kill_process(eval_pid, :kill)
        finish(session_pid, {:error, error})

      {^ref, {:done, result}} ->
        Process.demonitor(monitor_ref, [:flush])
        finish(session_pid, result)

      {:DOWN, ^monitor_ref, :process, ^eval_pid, :normal} ->
        receive do
          {^ref, {:done, result}} -> finish(session_pid, result)
        after
          0 -> finish(session_pid, {:ok, nil})
        end

      {:DOWN, ^monitor_ref, :process, ^eval_pid, reason} ->
        finish(session_pid, {:error, Error.command(:crashed, %{line: line, reason: reason})})
    after
      receive_timeout(timeout) ->
        kill_process(eval_pid, :kill)
        finish(session_pid, {:error, Error.command(:runtime_limit_exceeded, %{line: line, max_runtime_ms: timeout})})
    end
  end

  defp finish(session_pid, result) do
    send(session_pid, {:command_finished, result})
    result
  end

  defp limited_emit(session_pid, watcher_pid, limit_ref, output_limit) do
    counter = :counters.new(1, [])

    fn event ->
      case check_output_limit(event, counter, output_limit) do
        :ok ->
          send(session_pid, {:command_event, event})

        {:error, %Error{} = error} ->
          send(watcher_pid, {limit_ref, {:error, error}})
          throw({:lua_output_limit_exceeded, error})
      end

      :ok
    end
  end

  defp check_output_limit(_event, _counter, nil), do: :ok

  defp check_output_limit(event, counter, output_limit) do
    case output_size(event) do
      nil ->
        :ok

      chunk_bytes ->
        emitted_bytes = :counters.get(counter, 1)

        case OutputLimiter.check(chunk_bytes, emitted_bytes, output_limit) do
          {:ok, updated_total} ->
            :counters.put(counter, 1, updated_total)
            :ok

          {:limit_exceeded, %Error{} = error} ->
            {:error, error}
        end
    end
  end

  defp output_size({:output, chunk}), do: chunk |> IO.iodata_to_binary() |> byte_size()
  defp output_size({:output_stderr, chunk}), do: chunk |> IO.iodata_to_binary() |> byte_size()
  defp output_size(_event), do: nil

  defp receive_timeout(nil), do: :infinity
  defp receive_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout
  defp receive_timeout(_timeout), do: :infinity

  defp positive_limit(value) when is_integer(value) and value > 0, do: value
  defp positive_limit(_value), do: nil

  defp kill_process(pid, reason) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, reason)
    :ok
  end

  defp kill_process(_pid, _reason), do: :ok
end
