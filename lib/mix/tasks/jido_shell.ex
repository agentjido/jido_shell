defmodule Mix.Tasks.JidoShell do
  @moduledoc """
  Starts an interactive Jido.Shell session.

  ## Usage

      mix jido_shell              # IEx-style shell
      mix jido_shell --ui         # Rich terminal UI
      mix jido_shell --workspace my_workspace

  """

  use Mix.Task

  @shortdoc "Start interactive Jido.Shell"

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
      Jido.Shell.Transport.TermUI.start(workspace_id)
    else
      Jido.Shell.Transport.IEx.start(workspace_id)
    end
  end
end
