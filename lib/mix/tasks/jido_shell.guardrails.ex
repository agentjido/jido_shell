defmodule Mix.Tasks.JidoShell.Guardrails do
  @moduledoc """
  Enforces namespace and layout guardrails for Jido.Shell.
  """

  use Mix.Task

  @shortdoc "Validate Jido.Shell namespace/layout guardrails"

  @impl Mix.Task
  def run(_args) do
    case Jido.Shell.Guardrails.check(File.cwd!()) do
      :ok ->
        :ok

      {:error, violations} ->
        Mix.raise(Jido.Shell.Guardrails.format_violations(violations))
    end
  end
end
