defmodule Jido.Shell.Guardrails do
  @moduledoc false

  @collapsed_namespace_regex ~r/^\s*defmodule\s+(Jido[A-Z][\w\.]*)/m

  @type violation ::
          {:collapsed_namespace_module, %{path: String.t(), line: pos_integer(), module: String.t()}}
          | {:legacy_layout_path, %{path: String.t()}}

  @spec check(String.t()) :: :ok | {:error, [violation()]}
  def check(project_root \\ File.cwd!()) when is_binary(project_root) do
    violations = collapsed_namespace_violations(project_root) ++ legacy_layout_violations(project_root)

    if violations == [], do: :ok, else: {:error, violations}
  end

  @spec format_violations([violation()]) :: String.t()
  def format_violations(violations) when is_list(violations) do
    header =
      "Jido.Shell guardrails failed: detected namespace/layout regressions that violate the package convention."

    details =
      violations
      |> Enum.map(&format_violation/1)
      |> Enum.join("\n")

    [header, details]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp collapsed_namespace_violations(project_root) do
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
                 path: relative_path(project_root, path),
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

  defp legacy_layout_violations(project_root) do
    patterns = [
      Path.join([project_root, "lib", "jido", "shell.ex"]),
      Path.join([project_root, "lib", "jido", "shell", "**", "*.ex"])
    ]

    patterns
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.map(fn path ->
      {:legacy_layout_path, %{path: relative_path(project_root, path)}}
    end)
  end

  defp relative_path(project_root, path) do
    Path.relative_to(path, project_root)
  end

  defp format_violation({:collapsed_namespace_module, %{path: path, line: line, module: module}}) do
    "- collapsed namespace module `#{module}` in `#{path}:#{line}` (expected dotted form like `Jido.Shell.*`)"
  end

  defp format_violation({:legacy_layout_path, %{path: path}}) do
    "- legacy layout path `#{path}` detected (expected `lib/jido_shell.ex` + `lib/jido_shell/**/*.ex`)"
  end
end
