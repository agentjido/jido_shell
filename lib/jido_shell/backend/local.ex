defmodule Jido.Shell.Backend.Local do
  @moduledoc """
  Local backend implementation that uses `CommandRunner` and `Task.Supervisor`.
  """

  @behaviour Jido.Shell.Backend

  alias Jido.Shell.CommandRunner
  alias Jido.Shell.Error
  alias Jido.Shell.ShellSession.State

  @default_task_supervisor Jido.Shell.CommandTaskSupervisor

  @impl true
  def init(config) when is_map(config) do
    with {:ok, session_pid} <- fetch_session_pid(config) do
      {:ok,
       %{
         session_pid: session_pid,
         task_supervisor: Map.get(config, :task_supervisor, @default_task_supervisor),
         cwd: Map.get(config, :cwd, "/"),
         env: Map.get(config, :env, %{})
       }}
    end
  end

  @impl true
  def execute(state, command, args, exec_opts) when is_binary(command) and is_list(args) and is_list(exec_opts) do
    with %State{} = session_state <- Keyword.get(exec_opts, :session_state),
         {:ok, task_pid} <-
           Task.Supervisor.start_child(state.task_supervisor, fn ->
             CommandRunner.run(
               state.session_pid,
               override_session_state(session_state, exec_opts),
               command_line(command, args),
               runtime_opts(exec_opts)
             )
           end) do
      {:ok, task_pid, state}
    else
      nil ->
        {:error, Error.command(:start_failed, %{reason: :missing_session_state})}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def cancel(_state, command_ref) when is_pid(command_ref) do
    if Process.alive?(command_ref) do
      Process.exit(command_ref, :shutdown)
    end

    :ok
  end

  def cancel(_state, _command_ref), do: {:error, :invalid_command_ref}

  @impl true
  def terminate(_state), do: :ok

  @impl true
  def cwd(state), do: {:ok, state.cwd, state}

  @impl true
  def cd(state, path) when is_binary(path), do: {:ok, %{state | cwd: path}}

  @impl true
  def configure_network(state, _policy), do: {:ok, state}

  defp fetch_session_pid(config) do
    case Map.get(config, :session_pid) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> {:error, Error.session(:invalid_state_transition, %{reason: :missing_session_pid})}
    end
  end

  defp override_session_state(%State{} = session_state, exec_opts) do
    session_state
    |> maybe_override_cwd(Keyword.get(exec_opts, :dir))
    |> maybe_override_env(Keyword.get(exec_opts, :env))
  end

  defp maybe_override_cwd(state, nil), do: state
  defp maybe_override_cwd(state, cwd) when is_binary(cwd), do: State.set_cwd(state, cwd)
  defp maybe_override_cwd(state, _cwd), do: state

  defp maybe_override_env(state, nil), do: state
  defp maybe_override_env(state, env) when is_map(env), do: %{state | env: env}
  defp maybe_override_env(state, _env), do: state

  defp runtime_opts(exec_opts) do
    Keyword.drop(exec_opts, [:dir, :env, :timeout, :output_limit, :session_state])
  end

  defp command_line(command, []), do: command
  defp command_line(command, args), do: Enum.join([command | args], " ")
end
