defmodule Jido.Shell.SessionServer do
  @moduledoc """
  GenServer process for a Kodo session.

  Each session holds its own state (cwd, env, history) and manages
  transport subscriptions for streaming command output.
  """

  use GenServer

  alias Jido.Shell.Error
  alias Jido.Shell.Session
  alias Jido.Shell.Session.State

  # === Client API ===

  @doc """
  Starts a new SessionServer under the SessionSupervisor.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: Session.via_registry(session_id))
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

    {:ok, state} =
      State.new(%{
        id: session_id,
        workspace_id: workspace_id,
        cwd: Keyword.get(opts, :cwd, "/"),
        env: Keyword.get(opts, :env, %{}),
        meta: Keyword.get(opts, :meta, %{})
      })

    {:ok, state}
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
          updated_state = apply_state_updates(state, changes)

          # Broadcast state changes before command_done
          if Map.has_key?(changes, :cwd) do
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
    Enum.reduce(changes, state, fn {key, value}, acc ->
      case key do
        :cwd -> State.set_cwd(acc, value)
        :env -> %{acc | env: value}
        _ -> acc
      end
    end)
  end

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
      session_pid = self()

      case Task.Supervisor.start_child(
             Jido.Shell.CommandTaskSupervisor,
             fn -> Jido.Shell.CommandRunner.run(session_pid, state, line, opts) end
           ) do
        {:ok, task_pid} ->
          ref = Process.monitor(task_pid)

          new_state =
            state
            |> State.add_to_history(line)
            |> State.set_current_command(%{task: task_pid, ref: ref, line: line})

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

      %{task: task_pid, ref: ref} ->
        Process.demonitor(ref, [:flush])
        Process.exit(task_pid, :shutdown)

        broadcast(state, :command_cancelled)
        {{:ok, :cancelled}, State.clear_current_command(state)}
    end
  end

  defp with_session(session_id, fun) when is_binary(session_id) and byte_size(session_id) > 0 do
    case Session.lookup(session_id) do
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
