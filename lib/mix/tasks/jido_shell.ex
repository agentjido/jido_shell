defmodule Mix.Tasks.JidoShell do
  @moduledoc """
  Starts an interactive Jido.Shell session.

  ## Usage

      mix jido_shell              # IEx-style shell
      mix jido_shell --workspace my_workspace

  """

  use Mix.Task

  @shortdoc "Start interactive Jido.Shell"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [workspace: :string]
      )

    workspace_id = Keyword.get(opts, :workspace, "default")

    case Jido.Shell.Transport.IEx.start(workspace_id) do
      :ok ->
        :ok

      {:error, %Jido.Shell.Error{} = error} ->
        Mix.raise("failed to start shell: #{error.message}")

      {:error, reason} ->
        Mix.raise("failed to start shell: #{inspect(reason)}")
    end
  end
end
