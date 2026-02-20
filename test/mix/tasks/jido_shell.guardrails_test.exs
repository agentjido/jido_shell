defmodule Mix.Tasks.JidoShell.GuardrailsTest do
  use ExUnit.Case, async: true

  test "passes for the current project state" do
    Mix.Task.reenable("jido_shell.guardrails")
    assert :ok = Mix.Tasks.JidoShell.Guardrails.run([])
  end
end
