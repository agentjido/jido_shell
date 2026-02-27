# Guardrails Guide

`jido_shell` guardrails protect namespace and file-layout conventions so regressions are blocked before review.

Run guardrails directly:

```bash
mix jido_shell.guardrails
```

`mix quality` runs this task automatically.

## Current Conventions

Guardrails currently enforce:

- no legacy `kodo` namespace paths in `lib/` or `test/`
- canonical session module file layout
- deprecated `Session*` compatibility shims remain present and marked deprecated
- module prefixes align with their path roots (`Jido.Shell*`, `Mix.Tasks.JidoShell*`)

## Extending Guardrails

When namespace conventions evolve, update guardrails in the same PR.

1. Add a rule module that implements `Jido.Shell.Guardrails.Rule`.
2. Return `:ok` or a list of `%Jido.Shell.Guardrails.Violation{}` from `check/1`.
3. Register the rule:
4. Add it to `Jido.Shell.Guardrails.default_rules/0`, or
5. Configure it with `config :jido_shell, :guardrail_rules, [MyRule]`.
6. Add tests that demonstrate both pass and fail behavior for the new convention.

Example rule skeleton:

```elixir
defmodule Jido.Shell.Guardrails.Rules.MyConvention do
  @behaviour Jido.Shell.Guardrails.Rule
  alias Jido.Shell.Guardrails.Violation

  @impl true
  def check(%{root: root}) do
    if File.exists?(Path.join(root, "some/required/path")) do
      :ok
    else
      [%Violation{rule: __MODULE__, file: "some/required/path", message: "missing required path"}]
    end
  end
end
```
