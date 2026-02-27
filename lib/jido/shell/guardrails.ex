defmodule Jido.Shell.Guardrails do
  @moduledoc """
  Runs namespace and layout guardrails for the `jido_shell` codebase.

  Extension rules can be configured with:

      config :jido_shell, :guardrail_rules, [
        MyApp.CustomGuardrailRule
      ]
  """

  alias Jido.Shell.Guardrails.Violation

  @default_rules [
    Jido.Shell.Guardrails.Rules.ForbiddenPaths,
    Jido.Shell.Guardrails.Rules.RequiredFiles,
    Jido.Shell.Guardrails.Rules.NamespacePrefixes
  ]

  @type options :: [
          root: String.t(),
          rules: [module()]
        ]

  @spec check(options()) :: :ok | {:error, [Violation.t()]}
  def check(opts \\ []) do
    context = %{root: normalize_root(opts)}

    violations =
      opts
      |> rules()
      |> Enum.flat_map(&run_rule(&1, context))
      |> Enum.sort_by(fn %Violation{file: file, message: message} ->
        {file || "", message}
      end)

    case violations do
      [] -> :ok
      _ -> {:error, violations}
    end
  end

  @spec default_rules() :: [module()]
  def default_rules, do: @default_rules

  @spec configured_rules() :: [module()]
  def configured_rules do
    @default_rules
    |> Kernel.++(configured_extension_rules())
    |> Enum.uniq()
  end

  @spec format_violations([Violation.t()]) :: String.t()
  def format_violations(violations) do
    Enum.map_join(violations, "\n", fn %Violation{rule: rule, file: file, message: message} ->
      location = if file, do: " (#{file})", else: ""
      "[#{inspect(rule)}]#{location} #{message}"
    end)
  end

  defp normalize_root(opts) do
    opts
    |> Keyword.get(:root, File.cwd!())
    |> Path.expand()
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

  defp run_rule(rule, context) when is_atom(rule) do
    Code.ensure_loaded(rule)

    unless function_exported?(rule, :check, 1) do
      raise ArgumentError, "guardrail rule #{inspect(rule)} must define check/1"
    end

    case rule.check(context) do
      :ok -> []
      violations when is_list(violations) -> violations
    end
  end
end
