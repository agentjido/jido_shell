defmodule Mix.Tasks.Kodo do
  @moduledoc """
  Starts an interactive Kodo shell session.

  ## Usage

      mix kodo              # IEx-style shell
      mix kodo --ui         # Rich terminal UI
      mix kodo --workspace my_workspace

  """

  use Mix.Task

  @shortdoc "Start interactive Kodo shell"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [workspace: :string, ui: :boolean]
      )

    workspace_id =
      case Keyword.get(opts, :workspace) do
        nil -> :default
        name -> String.to_atom(name)
      end

    if Keyword.get(opts, :ui) do
      Kodo.Transport.TermUI.start(workspace_id)
    else
      Kodo.Transport.IEx.start(workspace_id)
    end
  end
end
