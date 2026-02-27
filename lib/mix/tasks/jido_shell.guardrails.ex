defmodule Mix.Tasks.JidoShell.Guardrails do
  @moduledoc """
  Verifies namespace and file layout guardrails for this repository.

  ## Usage

      mix jido_shell.guardrails
      mix jido_shell.guardrails --root /path/to/repo
  """

  use Mix.Task

  @shortdoc "Check namespace/layout guardrails"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [root: :string]
      )

    root = Keyword.get(opts, :root, File.cwd!())

    case Jido.Shell.Guardrails.check(root: root) do
      :ok ->
        Mix.shell().info("jido_shell guardrails: ok")
        :ok

      {:error, violations} ->
        formatted = Jido.Shell.Guardrails.format_violations(violations)

        Mix.raise("""
        jido_shell guardrails failed:

        #{formatted}
        """)
    end
  end
end
