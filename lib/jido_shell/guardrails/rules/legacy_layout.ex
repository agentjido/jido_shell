defmodule Jido.Shell.Guardrails.Rules.LegacyLayout do
  @moduledoc false
  @behaviour Jido.Shell.Guardrails.Rule

  @impl true
  def check(project_root) do
    patterns = [
      Path.join([project_root, "lib", "jido", "shell.ex"]),
      Path.join([project_root, "lib", "jido", "shell", "**", "*.ex"])
    ]

    patterns
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.map(fn path ->
      {:legacy_layout_path, %{path: Path.relative_to(path, project_root)}}
    end)
  end
end
