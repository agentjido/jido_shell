defmodule Mix.Tasks.JidoShell.Guardrails do
  @moduledoc """
  Enforces namespace and layout guardrails for Jido.Shell.
  """

  use Mix.Task

  @shortdoc "Validate Jido.Shell namespace/layout guardrails"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [root: :string]
      )

    root = Keyword.get(opts, :root, File.cwd!())

    case Jido.Shell.Guardrails.check(root) do
      :ok ->
        Mix.shell().info("jido_shell guardrails: ok")
        :ok

      {:error, violations} ->
        Mix.raise(Jido.Shell.Guardrails.format_violations(violations))
    end
  end
end
