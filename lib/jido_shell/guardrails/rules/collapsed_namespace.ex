defmodule Jido.Shell.Guardrails.Rules.CollapsedNamespace do
  @moduledoc false
  @behaviour Jido.Shell.Guardrails.Rule

  @collapsed_namespace_regex ~r/^\s*defmodule\s+(Jido[A-Z][\w\.]*)/m

  @impl true
  def check(project_root) do
    lib_paths = Path.wildcard(Path.join([project_root, "lib", "**", "*.ex"]))

    Enum.flat_map(lib_paths, fn path ->
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, index} ->
        case Regex.run(@collapsed_namespace_regex, line) do
          [_, module] ->
            [
              {:collapsed_namespace_module,
               %{
                 path: Path.relative_to(path, project_root),
                 line: index,
                 module: module
               }}
            ]

          _ ->
            []
        end
      end)
    end)
  end
end
