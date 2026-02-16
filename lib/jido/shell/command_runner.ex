defmodule Jido.Shell.CommandRunner do
  @moduledoc """
  Executes commands in Task processes and streams output back.
  """

  alias Jido.Shell.Error
  alias Jido.Shell.Command.Parser
  alias Jido.Shell.Command.Registry
  alias Jido.Shell.ShellSession.State

  @output_bytes_key :jido_shell_command_output_bytes

  @doc """
  Runs a command line in the context of a session.

  Called by ShellSessionServer in a Task under CommandTaskSupervisor.
  Sends messages back to the session_pid.
  """
  @spec run(pid(), State.t(), String.t(), keyword()) :: term()
  def run(session_pid, state, line, opts \\ []) do
    state = with_execution_context(state, opts)
    limits = execution_limits(state)
    emit = limited_emit(session_pid, limits.max_output_bytes)

    result = execute_with_limits(state, line, emit, limits)
    send(session_pid, {:command_finished, result})
    result
  end

  @doc """
  Executes a command and returns the result.
  """
  @spec execute(State.t(), String.t(), Jido.Shell.Command.emit()) :: Jido.Shell.Command.run_result()
  def execute(state, line, emit) do
    with {:ok, program} <- parse_program(line) do
      execute_program(state, program, emit)
    end
  end

  defp parse_program(line) do
    case Parser.parse_program(line) do
      {:ok, _} = ok ->
        ok

      {:error, :empty_command} ->
        {:error, Error.shell(:empty_command, %{line: line})}

      {:error, reason} ->
        {:error, Error.shell(:syntax_error, %{line: line, reason: reason})}
    end
  end

  defp execute_program(initial_state, program, emit) do
    final =
      Enum.reduce(program, %{state: initial_state, last_result: {:ok, nil}, state_updates: %{}}, fn entry, acc ->
        if entry.operator == :and_if and not ok_result?(acc.last_result) do
          acc
        else
          run_program_entry(acc, entry, emit)
        end
      end)

    finalize_program_result(final)
  end

  defp finalize_program_result(%{last_result: {:error, _} = error}), do: error

  defp finalize_program_result(%{last_result: {:ok, result}, state_updates: state_updates}) do
    if map_size(state_updates) == 0 do
      {:ok, result}
    else
      {:ok, {:state_update, state_updates}}
    end
  end

  defp execute_command(state, cmd_name, args, emit) do
    with {:ok, module} <- lookup_command(cmd_name),
         {:ok, validated_args} <- validate_args(module, cmd_name, args) do
      module.run(state, validated_args, emit)
    end
  end

  defp run_program_entry(acc, %{command: cmd_name, args: args}, emit) do
    case execute_command(acc.state, cmd_name, args, emit) do
      {:ok, {:state_update, changes}} ->
        %{
          acc
          | state: apply_state_updates(acc.state, changes),
            last_result: {:ok, nil},
            state_updates: Map.merge(acc.state_updates, changes)
        }

      {:ok, _} = ok ->
        %{acc | last_result: ok}

      {:error, _} = error ->
        %{acc | last_result: error}
    end
  end

  defp lookup_command(name) do
    case Registry.lookup(name) do
      {:ok, _} = result -> result
      {:error, :not_found} -> {:error, Jido.Shell.Error.shell(:unknown_command, %{name: name})}
    end
  end

  defp validate_args(module, cmd_name, args) do
    schema = module.schema()
    input = args_to_input(args)

    case Zoi.parse(schema, input) do
      {:ok, _} = result -> result
      {:error, errors} -> {:error, Jido.Shell.Error.validation(cmd_name, errors)}
    end
  end

  defp args_to_input(args) do
    %{args: args}
  end

  defp apply_state_updates(state, changes) do
    Enum.reduce(changes, state, fn {key, value}, acc ->
      case key do
        :cwd -> State.set_cwd(acc, value)
        :env -> %{acc | env: value}
        _ -> acc
      end
    end)
  end

  defp with_execution_context(%State{} = state, opts) do
    base_context =
      state.meta
      |> Map.get(:execution_context, %{})
      |> normalize_context()

    runtime_context =
      opts
      |> Keyword.get(:execution_context, %{})
      |> normalize_context()

    merged_context = deep_merge(base_context, runtime_context)
    %{state | meta: Map.put(state.meta, :execution_context, merged_context)}
  end

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

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_val, right_val ->
      deep_merge(left_val, right_val)
    end)
  end

  defp deep_merge(_left, right), do: right

  defp execute_with_limits(state, line, emit, %{max_runtime_ms: nil}) do
    execute_with_output_guard(state, line, emit)
  end

  defp execute_with_limits(state, line, emit, %{max_runtime_ms: max_runtime_ms}) do
    task = Task.async(fn -> execute_with_output_guard(state, line, emit) end)

    case Task.yield(task, max_runtime_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        {:error, Error.command(:runtime_limit_exceeded, %{line: line, max_runtime_ms: max_runtime_ms})}
    end
  end

  defp execute_with_output_guard(state, line, emit) do
    Process.put(@output_bytes_key, 0)

    try do
      execute(state, line, emit)
    catch
      :throw, {:output_limit_exceeded, %Error{} = error} ->
        {:error, error}
    after
      Process.delete(@output_bytes_key)
    end
  end

  defp limited_emit(session_pid, max_output_bytes) do
    fn event ->
      case enforce_output_limit(event, max_output_bytes) do
        :ok ->
          send(session_pid, {:command_event, event})
          :ok

        {:error, %Error{} = error} ->
          throw({:output_limit_exceeded, error})
      end
    end
  end

  defp enforce_output_limit(_event, nil), do: :ok

  defp enforce_output_limit({:output, chunk}, max_output_bytes)
       when is_integer(max_output_bytes) and max_output_bytes > 0 do
    emitted_bytes = Process.get(@output_bytes_key, 0)
    chunk_bytes = chunk |> IO.iodata_to_binary() |> byte_size()
    updated_total = emitted_bytes + chunk_bytes

    if updated_total > max_output_bytes do
      {:error,
       Error.command(:output_limit_exceeded, %{
         emitted_bytes: updated_total,
         max_output_bytes: max_output_bytes
       })}
    else
      Process.put(@output_bytes_key, updated_total)
      :ok
    end
  end

  defp enforce_output_limit(_event, _max_output_bytes), do: :ok

  defp execution_limits(%State{} = state) do
    execution_context = Map.get(state.meta, :execution_context, %{})
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

  defp ok_result?({:ok, _}), do: true
  defp ok_result?(_), do: false

  defp get_opt(data, key, default) when is_map(data) do
    Map.get(data, key, Map.get(data, Atom.to_string(key), default))
  end

  defp get_opt(data, key, default) when is_list(data) do
    if Keyword.keyword?(data) do
      Keyword.get(data, key, default)
    else
      default
    end
  end

  defp get_opt(_, _, default), do: default
end
