defmodule Jido.Shell.CommandRunner do
  @moduledoc """
  Executes commands in Task processes and streams output back.
  """

  alias Jido.Shell.Command.Parser
  alias Jido.Shell.Command.Registry
  alias Jido.Shell.Session.State

  @doc """
  Runs a command line in the context of a session.

  Called by SessionServer in a Task under CommandTaskSupervisor.
  Sends messages back to the session_pid.
  """
  @spec run(pid(), State.t(), String.t(), keyword()) :: term()
  def run(session_pid, state, line, _opts \\ []) do
    emit = fn event -> send(session_pid, {:command_event, event}) end

    result = execute(state, line, emit)
    send(session_pid, {:command_finished, result})
    result
  end

  @doc """
  Executes a command and returns the result.
  """
  @spec execute(State.t(), String.t(), Jido.Shell.Command.emit()) :: Jido.Shell.Command.run_result()
  def execute(state, line, emit) do
    with {:ok, cmd_name, args} <- Parser.parse(line),
         {:ok, module} <- lookup_command(cmd_name),
         {:ok, validated_args} <- validate_args(module, cmd_name, args) do
      module.run(state, validated_args, emit)
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
end
