defmodule Jido.Shell.Sandbox.Bash do
  @moduledoc """
  Executes bash-like scripts by dispatching each statement through the
  existing Jido.Shell command system.

  This keeps execution sandboxed to registered Jido.Shell commands and
  Jido.Shell.VFS-backed file operations.
  """

  alias Jido.Shell.CommandRunner
  alias Jido.Shell.Session.State

  @type execute_result :: {:ok, State.t()} | {:error, Jido.Shell.Error.t()} | {:error, term()}

  @doc """
  Executes a script in the current session context.

  Script lines are split on newlines and `;`, with blank lines and full-line
  comments (`# ...`) ignored.
  """
  @spec execute(State.t(), String.t(), Jido.Shell.Command.emit()) :: execute_result()
  def execute(%State{} = state, script, emit) when is_binary(script) do
    script
    |> statements()
    |> run_statements(state, emit)
  end

  @doc """
  Returns normalized script statements.
  """
  @spec statements(String.t()) :: [String.t()]
  def statements(script) when is_binary(script) do
    script
    |> String.split(~r/\r?\n/)
    |> Enum.flat_map(&String.split(&1, ";"))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&skip_statement?/1)
  end

  defp run_statements([], state, _emit), do: {:ok, state}

  defp run_statements([line | rest], state, emit) do
    case CommandRunner.execute(state, line, emit) do
      {:ok, {:state_update, changes}} ->
        run_statements(rest, apply_state_updates(state, changes), emit)

      {:ok, _} ->
        run_statements(rest, state, emit)

      {:error, _} = error ->
        error
    end
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

  defp skip_statement?(""), do: true
  defp skip_statement?(<<"#", _::binary>>), do: true
  defp skip_statement?(_), do: false
end
