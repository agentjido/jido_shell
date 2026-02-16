defmodule Jido.Shell.Command do
  @moduledoc """
  Behaviour for Jido.Shell commands.

  Commands implement a unified callback pattern with streaming support
  via an emit function.

  ## Example Implementation

      defmodule Jido.Shell.Command.Echo do
        @behaviour Jido.Shell.Command

        @impl true
        def name, do: "echo"

        @impl true
        def summary, do: "Print arguments to output"

        @impl true
        def schema do
          Zoi.map(%{
            args: Zoi.array(Zoi.string()) |> Zoi.default([])
          })
        end

        @impl true
        def run(_state, args, emit) do
          emit.({:output, Enum.join(args.args, " ") <> "\\n"})
          {:ok, nil}
        end
      end
  """

  alias Jido.Shell.ShellSession.State

  @type emit :: (event :: term() -> :ok)
  @type run_result :: {:ok, term()} | {:error, Jido.Shell.Error.t()}

  @doc "Returns the command name (e.g., \"echo\", \"ls\", \"cd\")"
  @callback name() :: String.t()

  @doc "Returns a short summary of the command"
  @callback summary() :: String.t()

  @doc "Returns the Zoi schema for command arguments"
  @callback schema() :: term()

  @doc """
  Executes the command.

  - `state` - Current session state
  - `args` - Validated arguments (map matching schema)
  - `emit` - Function to emit events like `{:output, chunk}`

  Returns `{:ok, result}` or `{:error, Jido.Shell.Error.t()}`.

  Commands that modify session state (like `cd`) should return
  `{:ok, {:state_update, changes}}` where changes is a map
  like `%{cwd: "/new/path"}`.
  """
  @callback run(state :: State.t(), args :: map(), emit :: emit()) :: run_result()
end
