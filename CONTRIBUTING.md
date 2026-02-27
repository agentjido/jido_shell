# Contributing to Jido.Shell

Thanks for contributing.

## Development Setup

```bash
git clone https://github.com/agentjido/jido_shell.git
cd jido_shell
mix setup
mix test
```

## Quality Bar

Run before opening a PR:

```bash
mix jido_shell.guardrails
mix quality
mix test
mix test --include flaky
mix coveralls
```

`mix quality` runs `mix jido_shell.guardrails`, so namespace/layout regressions fail early in scripted workflows.
See [GUARDRAILS.md](GUARDRAILS.md) for extension guidance.

## Common Commands

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --min-priority higher
mix dialyzer
mix docs
```

## Pull Requests

1. Branch from `main`.
2. Add tests for behavior changes.
3. Keep docs and examples in sync.
4. Use conventional commits.
5. If namespace/layout conventions change, update guardrails and guardrail tests in the same PR.

Examples:

```bash
git commit -m "feat(command): add xyz"
git commit -m "fix(session): return typed errors for missing sessions"
git commit -m "docs: update migration guide"
```

## Adding Commands

1. Add a module under `lib/jido_shell/command/` implementing `Jido.Shell.Command`.
2. Register it in `Jido.Shell.Command.Registry`.
3. Add tests under `test/jido/shell/command/`.
4. Update `README.md` command docs.

## Reporting Issues

Please include:

- Elixir/OTP versions
- Jido.Shell version
- Reproduction steps
- Expected vs actual behavior
- Logs/stack traces

## License

By contributing, you agree contributions are Apache-2.0 licensed.
