defmodule Kodo.SessionServer do
  @moduledoc """
  GenServer process for a Kodo session.

  Each session holds its own state (cwd, env, history) and manages
  transport subscriptions for streaming command output.
  """

  use GenServer

  alias Kodo.Session
  alias Kodo.Session.State

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
  - `{:kodo_session, session_id, {:output, chunk}}`
  - `{:kodo_session, session_id, :command_done}`
  """
  @spec subscribe(String.t(), pid(), keyword()) :: :ok
  def subscribe(session_id, transport_pid, opts \\ []) do
    GenServer.call(Session.via_registry(session_id), {:subscribe, transport_pid, opts})
  end

  @doc """
  Unsubscribes a transport from session events.
  """
  @spec unsubscribe(String.t(), pid()) :: :ok
  def unsubscribe(session_id, transport_pid) do
    GenServer.call(Session.via_registry(session_id), {:unsubscribe, transport_pid})
  end

  @doc """
  Gets a snapshot of the current session state.
  """
  @spec get_state(String.t()) :: {:ok, State.t()}
  def get_state(session_id) do
    GenServer.call(Session.via_registry(session_id), :get_state)
  end

  @doc """
  Runs a command in the session.
  """
  @spec run_command(String.t(), String.t(), keyword()) :: :ok
  def run_command(session_id, line, opts \\ []) do
    GenServer.cast(Session.via_registry(session_id), {:run_command, line, opts})
  end

  @doc """
  Cancels the currently running command.
  """
  @spec cancel(String.t()) :: :ok
  def cancel(session_id) do
    GenServer.cast(Session.via_registry(session_id), :cancel)
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
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:unsubscribe, transport_pid}, _from, state) do
    new_state = State.remove_transport(state, transport_pid)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_cast({:run_command, line, opts}, state) do
    if State.command_running?(state) do
      broadcast(state, {:error, Kodo.Error.shell(:busy)})
      {:noreply, state}
    else
      session_pid = self()

      {:ok, task_pid} =
        Task.Supervisor.start_child(
          Kodo.CommandTaskSupervisor,
          fn -> Kodo.CommandRunner.run(session_pid, state, line, opts) end
        )

      ref = Process.monitor(task_pid)

      new_state =
        state
        |> State.add_to_history(line)
        |> State.set_current_command(%{task: task_pid, ref: ref, line: line})

      broadcast(new_state, {:command_started, line})
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast(:cancel, state) do
    case state.current_command do
      nil ->
        {:noreply, state}

      %{task: task_pid, ref: ref} ->
        Process.demonitor(ref, [:flush])
        Process.exit(task_pid, :shutdown)

        broadcast(state, :command_cancelled)
        {:noreply, State.clear_current_command(state)}
    end
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
      send(pid, {:kodo_session, state.id, event})
    end
  end
end
