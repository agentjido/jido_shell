# Contributing to Kodo

Thank you for your interest in contributing to Kodo! This document provides guidelines and instructions for contributing.

## Development Setup

1. Clone the repository:

```bash
git clone https://github.com/agentjido/kodo.git
cd kodo
```

2. Install dependencies and set up git hooks:

```bash
mix setup
```

3. Run tests to verify your setup:

```bash
mix test
```

## Development Workflow

### Running Quality Checks

Before submitting a PR, ensure all quality checks pass:

```bash
# Run all quality checks
mix quality

# Or run individually:
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --min-priority higher
mix dialyzer
```

### Running Tests

```bash
# Run tests
mix test

# Run tests with coverage
mix coveralls.html

# Run specific test file
mix test test/kodo/agent_test.exs

# Run tests matching a pattern
mix test --only describe:"basic shell operations"
```

### Code Style

- Follow standard Elixir conventions
- Use `mix format` before committing
- Keep functions small and focused
- Add `@doc` and `@spec` for public functions
- Use pattern matching over conditionals where appropriate

## Commit Messages

We use [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

### Types

| Type | Description |
|------|-------------|
| `feat` | New feature |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `style` | Formatting, no code change |
| `refactor` | Code change, no fix or feature |
| `perf` | Performance improvement |
| `test` | Adding/fixing tests |
| `chore` | Maintenance, deps, tooling |
| `ci` | CI/CD changes |

### Examples

```bash
git commit -m "feat(command): add mv command for moving files"
git commit -m "fix(vfs): resolve path traversal in relative paths"
git commit -m "docs: improve API documentation examples"
git commit -m "feat!: breaking change to session API"
```

## Pull Request Process

1. Create a feature branch from `main`:
   ```bash
   git checkout -b feat/my-feature
   ```

2. Make your changes with appropriate tests

3. Ensure all checks pass:
   ```bash
   mix quality
   mix test
   ```

4. Push and create a Pull Request

5. Respond to review feedback

## Adding New Commands

To add a new command:

1. Create a module implementing `Kodo.Command` behaviour:

```elixir
defmodule Kodo.Command.MyCommand do
  @behaviour Kodo.Command

  @impl true
  def name, do: "mycommand"

  @impl true
  def summary, do: "Brief description"

  @impl true
  def schema do
    Zoi.map(%{
      args: Zoi.array(Zoi.string()) |> Zoi.default([])
    })
  end

  @impl true
  def run(state, args, emit) do
    # Implementation
    emit.({:output, "Result\n"})
    {:ok, nil}
  end
end
```

2. Register it in `Kodo.Command.Registry`

3. Add tests in `test/kodo/command/my_command_test.exs`

4. Update the README command table

## Reporting Issues

When reporting issues, please include:

- Elixir and OTP versions (`elixir --version`)
- Kodo version
- Steps to reproduce
- Expected vs actual behavior
- Any error messages or stack traces

## Questions?

- Open a [GitHub Discussion](https://github.com/agentjido/kodo/discussions)
- Join our [Discord](https://agentjido.xyz/discord)

## License

By contributing, you agree that your contributions will be licensed under the Apache-2.0 License.
