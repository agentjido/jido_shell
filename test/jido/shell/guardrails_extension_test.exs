defmodule Jido.Shell.GuardrailsExtensionTest do
  use ExUnit.Case, async: false

  alias Jido.Shell.Guardrails
  alias Jido.Shell.Guardrails.Rules.ForbiddenPaths
  alias Jido.Shell.Guardrails.Violation

  defmodule CustomConventionRule do
    @behaviour Jido.Shell.Guardrails.Rule

    @impl true
    def check(_context) do
      [
        %Violation{
          rule: __MODULE__,
          message: "custom convention violation"
        }
      ]
    end
  end

  setup do
    previous_rules = Application.get_env(:jido_shell, :guardrail_rules)

    on_exit(fn ->
      if is_nil(previous_rules) do
        Application.delete_env(:jido_shell, :guardrail_rules)
      else
        Application.put_env(:jido_shell, :guardrail_rules, previous_rules)
      end
    end)

    :ok
  end

  test "configured extension rules are appended to default rules" do
    Application.put_env(:jido_shell, :guardrail_rules, [CustomConventionRule])

    assert {:error, violations} = Guardrails.check(root: File.cwd!())

    assert Enum.any?(violations, fn
             %Violation{rule: CustomConventionRule, message: "custom convention violation"} -> true
             _ -> false
           end)
  end

  test "explicit rules option bypasses configured extension rules for targeted checks" do
    Application.put_env(:jido_shell, :guardrail_rules, [CustomConventionRule])

    assert :ok = Guardrails.check(root: File.cwd!(), rules: [ForbiddenPaths])
  end

  test "invalid configured extension rules raise a clear error" do
    Application.put_env(:jido_shell, :guardrail_rules, ["not-a-module"])

    assert_raise ArgumentError, ~r/must be a module atom/, fn ->
      Guardrails.check(root: File.cwd!())
    end
  end
end
