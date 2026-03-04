defmodule Jido.Shell.Guardrails do
  @moduledoc """
  Guardrails that enforce `jido_shell` namespace and layout conventions.

  Extension rules can be configured with:

      config :jido_shell, :guardrail_rules, [
        MyApp.CustomGuardrailRule
      ]
  """

  @type violation ::
          {:collapsed_namespace_module, %{path: String.t(), line: pos_integer(), module: String.t()}}
          | {:legacy_layout_path, %{path: String.t()}}

  @default_rules [
    Jido.Shell.Guardrails.Rules.CollapsedNamespace,
    Jido.Shell.Guardrails.Rules.LegacyLayout
  ]

  @type option :: {:rules, [module()]}
  @type options :: [option()]

  @spec check(String.t(), options()) :: :ok | {:error, [violation()]}
  def check(project_root \\ File.cwd!(), opts \\ []) when is_binary(project_root) and is_list(opts) do
    violations =
      opts
      |> rules()
      |> Enum.flat_map(&run_rule(&1, project_root))

    if violations == [], do: :ok, else: {:error, violations}
  end

  @spec default_rules() :: [module()]
  def default_rules, do: @default_rules

  @spec configured_rules() :: [module()]
  def configured_rules do
    @default_rules
    |> Kernel.++(configured_extension_rules())
    |> Enum.uniq()
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

  defp rules(opts) do
    opts
    |> Keyword.get(:rules, configured_rules())
    |> normalize_rules!()
  end

  defp configured_extension_rules do
    :jido_shell
    |> Application.get_env(:guardrail_rules, [])
    |> List.wrap()
    |> normalize_rules!()
  end

  defp normalize_rules!(rules) when is_list(rules) do
    Enum.map(rules, fn rule ->
      if is_atom(rule) do
        rule
      else
        raise ArgumentError, "guardrail rule #{inspect(rule)} must be a module atom"
      end
    end)
  end

  defp run_rule(rule, project_root) do
    Code.ensure_loaded(rule)

    unless function_exported?(rule, :check, 1) do
      raise ArgumentError, "guardrail rule #{inspect(rule)} must define check/1"
    end

    case rule.check(project_root) do
      :ok -> []
      violations when is_list(violations) -> violations
    end
  end

  defp format_violation({:collapsed_namespace_module, %{path: path, line: line, module: module}}) do
    "- collapsed namespace module `#{module}` in `#{path}:#{line}` (expected dotted form like `Jido.Shell.*`)"
  end

  defp format_violation({:legacy_layout_path, %{path: path}}) do
    "- legacy layout path `#{path}` detected (expected `lib/jido_shell.ex` + `lib/jido_shell/**/*.ex`)"
  end
end
