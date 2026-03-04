defmodule Jido.Shell.GuardrailsExtensionTest do
  use ExUnit.Case, async: false

  alias Jido.Shell.Guardrails
  alias Jido.Shell.Guardrails.Rules.LegacyLayout

  defmodule CustomConventionRule do
    @behaviour Jido.Shell.Guardrails.Rule

    @impl true
    def check(_project_root) do
      [{:legacy_layout_path, %{path: "custom/rule/path"}}]
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

    assert {:error, violations} = Guardrails.check(File.cwd!())

    assert {:legacy_layout_path, %{path: "custom/rule/path"}} in violations
  end

  test "explicit rules option bypasses configured extension rules for targeted checks" do
    Application.put_env(:jido_shell, :guardrail_rules, [CustomConventionRule])

    assert :ok = Guardrails.check(File.cwd!(), rules: [LegacyLayout])
  end

  test "invalid configured extension rules raise a clear error" do
    Application.put_env(:jido_shell, :guardrail_rules, ["not-a-module"])

    assert_raise ArgumentError, ~r/must be a module atom/, fn ->
      Guardrails.check(File.cwd!())
    end
  end
end
