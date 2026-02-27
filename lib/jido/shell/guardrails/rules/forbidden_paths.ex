defmodule Jido.Shell.Guardrails.Rules.ForbiddenPaths do
  @moduledoc false
  @behaviour Jido.Shell.Guardrails.Rule

  alias Jido.Shell.Guardrails.Violation

  @forbidden_paths [
    "lib/kodo",
    "test/kodo",
    "lib/mix/tasks/kodo.ui.ex"
  ]

  @impl true
  def check(%{root: root}) do
    @forbidden_paths
    |> Enum.filter(&(root |> Path.join(&1) |> File.exists?()))
    |> Enum.map(fn path ->
      %Violation{
        rule: __MODULE__,
        file: path,
        message: "legacy namespace path exists: #{path}"
      }
    end)
  end
end
