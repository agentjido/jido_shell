defmodule Jido.Shell.Guardrails.Rules.NamespacePrefixes do
  @moduledoc false
  @behaviour Jido.Shell.Guardrails.Rule

  alias Jido.Shell.Guardrails.Violation

  @module_pattern ~r/^\s*defmodule\s+([A-Za-z0-9_.]+)\s+do/m

  @file_prefix_rules [
    {"lib/jido/shell/**/*.ex", "Jido.Shell"},
    {"lib/mix/tasks/jido_shell*.ex", "Mix.Tasks.JidoShell"}
  ]

  @impl true
  def check(%{root: root}) do
    Enum.flat_map(@file_prefix_rules, fn {glob, prefix} ->
      root
      |> Path.join(glob)
      |> Path.wildcard()
      |> Enum.flat_map(fn file ->
        relative = Path.relative_to(file, root)
        file_namespace_violations(file, relative, prefix)
      end)
    end)
  end

  defp file_namespace_violations(file, relative, prefix) do
    modules =
      file
      |> File.read!()
      |> modules_in_file()

    case modules do
      [] ->
        [
          %Violation{
            rule: __MODULE__,
            file: relative,
            message: "no module definition found for namespace check"
          }
        ]

      _ ->
        modules
        |> Enum.reject(&String.starts_with?(&1, prefix))
        |> Enum.map(fn module_name ->
          %Violation{
            rule: __MODULE__,
            file: relative,
            message: "module #{module_name} does not use expected prefix #{prefix}"
          }
        end)
    end
  end

  defp modules_in_file(contents) do
    @module_pattern
    |> Regex.scan(contents, capture: :all_but_first)
    |> Enum.map(fn [module_name] -> module_name end)
  end
end
