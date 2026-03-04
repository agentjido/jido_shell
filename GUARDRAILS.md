# Guardrails Guide

`jido_shell` guardrails protect namespace and file-layout conventions so regressions fail early in development and CI.

Run guardrails directly:

```bash
mix jido_shell.guardrails
```

`mix quality` runs this task automatically.

## Current Conventions

Guardrails currently enforce:

- no collapsed namespace modules (for example `JidoShell.Foo`)
- no legacy `lib/jido/shell` layout paths

## Extending Guardrails

When conventions evolve, update guardrails and tests in the same PR.

1. Add a rule module implementing `Jido.Shell.Guardrails.Rule`.
2. Return `:ok` or a list of `Jido.Shell.Guardrails.violation()` tuples from `check/1`.
3. Register the rule by either:
4. Adding it to `Jido.Shell.Guardrails.default_rules/0`.
5. Configuring it via `config :jido_shell, :guardrail_rules, [MyRule]`.
6. Add tests showing both pass and fail behavior for the new convention.

Example:

```elixir
defmodule Jido.Shell.Guardrails.Rules.MyConvention do
  @behaviour Jido.Shell.Guardrails.Rule

  @impl true
  def check(project_root) do
    path = Path.join(project_root, "some/required/path")

    if File.exists?(path) do
      :ok
    else
      [{:legacy_layout_path, %{path: "some/required/path"}}]
    end
  end
end
```
