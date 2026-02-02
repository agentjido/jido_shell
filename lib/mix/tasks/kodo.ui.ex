defmodule Mix.Tasks.Kodo.Ui do
  @shortdoc "Starts Kodo shell with rich terminal UI"
  @moduledoc """
  Starts an interactive Kodo shell session with the TermUI interface.

  ## Usage

      mix kodo.ui WORKSPACE_NAME

  ## Examples

      mix kodo.ui my_workspace
      mix kodo.ui test

  Press Ctrl+C or type "exit" to quit.

  Note: This task must be run outside of IEx since the terminal UI
  requires exclusive terminal control.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [workspace_name] ->
        workspace_id = String.to_atom(workspace_name)
        Kodo.Transport.TermUI.start(workspace_id)

      [] ->
        Kodo.Transport.TermUI.start(:default)

      _ ->
        Mix.shell().error("Usage: mix kodo.ui [WORKSPACE_NAME]")
        exit({:shutdown, 1})
    end
  end
end
