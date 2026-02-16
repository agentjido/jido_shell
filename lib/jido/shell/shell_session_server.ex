defmodule Jido.Shell.ShellSessionServer do
  @moduledoc """
  GenServer process for a shell session.

  Each session holds its own state (cwd, env, history) and manages
  transport subscriptions for streaming command output.
  """

  use GenServer

  alias Jido.Shell.Error
  alias Jido.Shell.ShellSession
  alias Jido.Shell.ShellSession.State

  @default_backend Jido.Shell.Backend.Local

  # === Client API ===

  @doc """
  Starts a new ShellSessionServer under the SessionSupervisor.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: ShellSession.via_registry(session_id))
  end

  @doc """
  Subscribes a transport to receive session events.

  The transport will receive messages like:
  - `{:jido_shell_session, session_id, {:output, chunk}}`
  - `{:jido_shell_session, session_id, :command_done}`
  """
  @spec subscribe(String.t(), pid(), keyword()) ::
          {:ok, :subscribed} | {:error, Error.t()}
  def subscribe(session_id, transport_pid, opts \\ []) do
    with_session(session_id, fn pid ->
      GenServer.call(pid, {:subscribe, transport_pid, opts})
    end)
  end

  @doc """
  Unsubscribes a transport from session events.
  """
  @spec unsubscribe(String.t(), pid()) ::
          {:ok, :unsubscribed} | {:error, Error.t()}
  def unsubscribe(session_id, transport_pid) do
    with_session(session_id, fn pid ->
      GenServer.call(pid, {:unsubscribe, transport_pid})
    end)
  end

  @doc """
  Gets a snapshot of the current session state.
  """
  @spec get_state(String.t()) :: {:ok, State.t()} | {:error, Error.t()}
  def get_state(session_id) do
    with_session(session_id, fn pid ->
      GenServer.call(pid, :get_state)
    end)
  end

  @doc """
  Runs a command in the session.

  `opts` are passed to the command task context (for example
  `execution_context: %{network: %{allow_domains: [...]}}`).
  """
  @spec run_command(String.t(), String.t(), keyword()) ::
          {:ok, :accepted} | {:error, Error.t()}
  def run_command(session_id, line, opts \\ []) do
    with_session(session_id, fn pid ->
      GenServer.call(pid, {:run_command, line, opts})
    end)
  end

  @doc """
  Cancels the currently running command.
  """
  @spec cancel(String.t()) :: {:ok, :cancelled} | {:error, Error.t()}
  def cancel(session_id) do
    with_session(session_id, fn pid ->
      GenServer.call(pid, :cancel)
    end)
  end

  # === Server Callbacks ===

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    cwd = Keyword.get(opts, :cwd, "/")
    env = Keyword.get(opts, :env, %{})
    meta = Keyword.get(opts, :meta, %{})

    with {:ok, {backend, backend_config}} <-
           normalize_backend_spec(Keyword.get(opts, :backend, {@default_backend, %{}})),
         :ok <- ensure_backend_module(backend),
         {:ok, backend_state} <- init_backend(backend, backend_config, session_id, workspace_id, cwd, env, meta),
         {:ok, state} <-
           State.new(%{
             id: session_id,
             workspace_id: workspace_id,
             cwd: cwd,
             env: env,
             meta: meta,
             backend: backend,
             backend_state: backend_state
           }) do
      {:ok, state}
    else
      {:error, %Error{} = error} ->
        {:stop, error}

      {:error, reason} ->
        {:stop, Error.command(:start_failed, %{reason: reason})}
    end
  end

  @impl true
  def terminate(_reason, state) do
    _ = safe_backend_terminate(state.backend, state.backend_state)
    :ok
  end

  @impl true
  def handle_call({:subscribe, transport_pid, _opts}, _from, state) do
    Process.monitor(transport_pid)
    new_state = State.add_transport(state, transport_pid)
    {:reply, {:ok, :subscribed}, new_state}
  end

  @impl true
  def handle_call({:unsubscribe, transport_pid}, _from, state) do
    new_state = State.remove_transport(state, transport_pid)
    {:reply, {:ok, :unsubscribed}, new_state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_call({:run_command, line, opts}, _from, state) do
    {reply, new_state} = do_run_command(state, line, opts)
    {:reply, reply, new_state}
  end

  @impl true
  def handle_call(:cancel, _from, state) do
    {reply, new_state} = do_cancel(state)
    {:reply, reply, new_state}
  end

  @impl true
  def handle_cast({:run_command, line, opts}, state) do
    {_reply, new_state} = do_run_command(state, line, opts)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:cancel, state) do
    {_reply, new_state} = do_cancel(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:command_event, _event}, %{current_command: nil} = state) do
    # Late message from cancelled command, ignore
    {:noreply, state}
  end

  @impl true
  def handle_info({:command_event, event}, state) do
    broadcast(state, event)
    {:noreply, state}
  end

  @impl true
  def handle_info({:command_finished, _result}, %{current_command: nil} = state) do
    # Late message from cancelled command, ignore
    {:noreply, state}
  end

  @impl true
  def handle_info({:command_finished, result}, state) do
    new_state =
      case result do
        {:ok, {:state_update, changes}} ->
          {updated_state, cwd_changed?} = apply_state_updates(state, changes)

          # Broadcast state changes before command_done
          if cwd_changed? do
            broadcast(updated_state, {:cwd_changed, updated_state.cwd})
          end

          broadcast(updated_state, :command_done)
          updated_state

        {:ok, _} ->
          broadcast(state, :command_done)
          state

        {:error, error} ->
          broadcast(state, {:error, error})
          state
      end

    {:noreply, State.clear_current_command(new_state)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    cond do
      state.current_command && state.current_command.ref == ref ->
        case reason do
          :normal ->
            # Normal exit - finished message should have arrived
            {:noreply, state}

          :shutdown ->
            # We cancelled it - already broadcast :command_cancelled
            {:noreply, State.clear_current_command(state)}

          _ ->
            # Crashed unexpectedly
            broadcast(state, {:command_crashed, reason})
            {:noreply, State.clear_current_command(state)}
        end

      MapSet.member?(state.transports, pid) ->
        {:noreply, State.remove_transport(state, pid)}

      true ->
        {:noreply, state}
    end
  end

  # === Private ===

  defp apply_state_updates(state, changes) do
    updated_state =
      Enum.reduce(changes, state, fn {key, value}, acc ->
        case key do
          :cwd -> State.set_cwd(acc, value)
          :env -> %{acc | env: value}
          _ -> acc
        end
      end)

    updated_state = maybe_sync_backend_cwd(updated_state, Map.get(changes, :cwd))
    {updated_state, Map.has_key?(changes, :cwd)}
  end

  defp maybe_sync_backend_cwd(state, nil), do: state

  defp maybe_sync_backend_cwd(state, cwd) when is_binary(cwd) do
    case safe_backend_cd(state.backend, state.backend_state, cwd) do
      {:ok, backend_state} -> %{state | backend_state: backend_state}
      _ -> state
    end
  end

  defp maybe_sync_backend_cwd(state, _cwd), do: state

  defp broadcast(state, event) do
    for pid <- state.transports do
      send(pid, {:jido_shell_session, state.id, event})
    end
  end

  defp do_run_command(state, line, opts) do
    if State.command_running?(state) do
      error = Error.shell(:busy)
      broadcast(state, {:error, error})
      {{:error, error}, state}
    else
      case safe_backend_execute(state.backend, state.backend_state, line, [], backend_exec_opts(state, opts)) do
        {:ok, command_ref, backend_state} ->
          {task_pid, ref} = monitor_for_command(command_ref)

          current_command = %{
            task: task_pid,
            ref: ref,
            line: line,
            backend_ref: command_ref
          }

          new_state =
            state
            |> Map.put(:backend_state, backend_state)
            |> State.add_to_history(line)
            |> State.set_current_command(current_command)

          broadcast(new_state, {:command_started, line})
          {{:ok, :accepted}, new_state}

        {:error, reason} ->
          {{:error, Error.command(:start_failed, %{reason: reason, line: line})}, state}
      end
    end
  end

  defp do_cancel(state) do
    case state.current_command do
      nil ->
        error = Error.session(:invalid_state_transition, %{state: :idle, action: :cancel})
        {{:error, error}, state}

      command ->
        maybe_demonitor(command.ref)

        command_ref =
          case Map.get(command, :backend_ref) do
            nil -> command.task
            ref -> ref
          end

        case safe_backend_cancel(state.backend, state.backend_state, command_ref) do
          :ok ->
            broadcast(state, :command_cancelled)
            {{:ok, :cancelled}, State.clear_current_command(state)}

          {:error, reason} ->
            error = Error.command(:cancel_failed, %{line: command.line, reason: reason})
            broadcast(state, {:error, error})
            {{:error, error}, state}
        end
    end
  end

  defp maybe_demonitor(ref) when is_reference(ref), do: Process.demonitor(ref, [:flush])
  defp maybe_demonitor(_), do: :ok

  defp monitor_for_command(command_ref) when is_pid(command_ref) do
    {command_ref, Process.monitor(command_ref)}
  end

  defp monitor_for_command(%{monitor_pid: pid}) when is_pid(pid) do
    {pid, Process.monitor(pid)}
  end

  defp monitor_for_command(_command_ref), do: {nil, nil}

  defp init_backend(backend, backend_config, session_id, workspace_id, cwd, env, meta) do
    config =
      Map.merge(
        %{
          session_id: session_id,
          workspace_id: workspace_id,
          cwd: cwd,
          env: env,
          meta: meta,
          session_pid: self(),
          task_supervisor: Jido.Shell.CommandTaskSupervisor
        },
        backend_config
      )

    backend.init(config)
  end

  defp normalize_backend_spec({backend, config}) when is_atom(backend) and is_map(config) do
    {:ok, {backend, config}}
  end

  defp normalize_backend_spec(backend) when is_atom(backend) do
    {:ok, {backend, %{}}}
  end

  defp normalize_backend_spec(other) do
    {:error, Error.session(:invalid_state_transition, %{reason: {:invalid_backend_spec, other}})}
  end

  defp ensure_backend_module(backend) do
    cond do
      not Code.ensure_loaded?(backend) ->
        {:error, Error.session(:invalid_state_transition, %{reason: {:backend_not_loaded, backend}})}

      not function_exported?(backend, :init, 1) ->
        {:error, Error.session(:invalid_state_transition, %{reason: {:invalid_backend, backend}})}

      true ->
        :ok
    end
  end

  defp backend_exec_opts(state, opts) do
    execution_context =
      opts
      |> Keyword.get(:execution_context, %{})
      |> normalize_context()

    limits = execution_limits(execution_context)

    opts
    |> Keyword.put(:dir, state.cwd)
    |> Keyword.put(:env, state.env)
    |> Keyword.put(:execution_context, execution_context)
    |> Keyword.put(:session_state, state)
    |> maybe_put_limit(:timeout, limits.max_runtime_ms)
    |> maybe_put_limit(:output_limit, limits.max_output_bytes)
  end

  defp maybe_put_limit(opts, _key, nil), do: opts
  defp maybe_put_limit(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_context(value) when is_map(value) do
    Enum.into(value, %{}, fn {key, val} ->
      {key, normalize_context(val)}
    end)
  end

  defp normalize_context(value) when is_list(value) do
    if Keyword.keyword?(value) do
      Enum.into(value, %{}, fn {key, val} ->
        {key, normalize_context(val)}
      end)
    else
      Enum.map(value, &normalize_context/1)
    end
  end

  defp normalize_context(value), do: value

  defp execution_limits(execution_context) do
    limits = get_opt(execution_context, :limits, %{})

    %{
      max_runtime_ms: parse_limit(get_opt(limits, :max_runtime_ms, get_opt(execution_context, :max_runtime_ms, nil))),
      max_output_bytes:
        parse_limit(get_opt(limits, :max_output_bytes, get_opt(execution_context, :max_output_bytes, nil)))
    }
  end

  defp parse_limit(value) when is_integer(value) and value > 0, do: value

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_limit(_), do: nil

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

  defp safe_backend_execute(backend, backend_state, command, args, exec_opts) do
    backend.execute(backend_state, command, args, exec_opts)
  rescue
    error -> {:error, {:backend_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:backend_throw, kind, reason}}
  end

  defp safe_backend_cancel(backend, backend_state, command_ref) do
    backend.cancel(backend_state, command_ref)
  rescue
    error -> {:error, {:backend_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:backend_throw, kind, reason}}
  end

  defp safe_backend_cd(backend, backend_state, cwd) do
    backend.cd(backend_state, cwd)
  rescue
    _ -> {:error, :backend_cd_failed}
  catch
    _, _ -> {:error, :backend_cd_failed}
  end

  defp safe_backend_terminate(backend, backend_state) do
    backend.terminate(backend_state)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp with_session(session_id, fun) when is_binary(session_id) and byte_size(session_id) > 0 do
    case ShellSession.lookup(session_id) do
      {:ok, pid} ->
        try do
          fun.(pid)
        catch
          :exit, _ -> {:error, Error.session(:not_found, %{session_id: session_id})}
        end

      {:error, :not_found} ->
        {:error, Error.session(:not_found, %{session_id: session_id})}
    end
  end

  defp with_session(session_id, _fun) do
    {:error, Error.session(:invalid_session_id, %{session_id: session_id})}
  end
end
