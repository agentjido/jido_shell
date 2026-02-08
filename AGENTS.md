# Agent Guide for Jido.Shell

## Purpose

Jido.Shell is an Elixir-native virtual shell system that provides multi-instance interactive sessions with virtual file system support. It's designed to be embedded in any BEAM application, offering an interactive REPL and full programmatic API for spawning sessions, evaluating commands, and manipulating virtual file systems.

## Commands

```bash
# Development
mix setup              # Install deps and git hooks
mix compile --warnings-as-errors
mix test               # Run tests (excludes flaky)
mix test --include flaky  # Run all tests
mix coveralls.html     # Test coverage report

# Quality
mix quality            # All checks (format, compile, credo, dialyzer)
mix q                  # Alias for quality
mix format             # Auto-format code
mix credo              # Linting
mix dialyzer           # Type checking

# Documentation
mix docs               # Generate docs

# Interactive
mix kodo               # IEx-style shell
mix kodo --ui          # Rich terminal UI
```

## Architecture

### Supervision Tree

```
Jido.Shell.Supervisor
├── Registry (Jido.Shell.SessionRegistry)
├── DynamicSupervisor (Jido.Shell.SessionSupervisor)
│   └── SessionServer processes
├── DynamicSupervisor (Jido.Shell.FilesystemSupervisor)
│   └── Hako adapter processes
└── Task.Supervisor (Jido.Shell.CommandTaskSupervisor)
    └── Command task processes
```

### Key Modules

| Module | Purpose |
|--------|---------|
| `Jido.Shell.Agent` | Programmatic API for agents (synchronous) |
| `Jido.Shell.Session` | Session lifecycle management |
| `Jido.Shell.SessionServer` | Per-session GenServer with state and subscriptions |
| `Jido.Shell.Command` | Command behaviour definition |
| `Jido.Shell.Command.Registry` | Command lookup and registration |
| `Jido.Shell.CommandRunner` | Task-based command execution |
| `Jido.Shell.VFS` | Virtual filesystem router |
| `Jido.Shell.VFS.MountTable` | ETS-backed mount table |
| `Jido.Shell.Transport.IEx` | Interactive IEx transport |
| `Jido.Shell.Transport.TermUI` | Rich terminal UI transport |

### Command Pattern

Commands implement `Jido.Shell.Command` behaviour:

```elixir
defmodule Jido.Shell.Command.Example do
  @behaviour Jido.Shell.Command

  @impl true
  def name, do: "example"

  @impl true
  def summary, do: "Example command"

  @impl true
  def schema do
    Zoi.map(%{
      args: Zoi.array(Zoi.string()) |> Zoi.default([])
    })
  end

  @impl true
  def run(state, args, emit) do
    emit.({:output, "Hello\n"})
    {:ok, nil}  # or {:ok, {:state_update, %{cwd: "/new/path"}}}
  end
end
```

### Session Events

```elixir
{:kodo_session, session_id, event}

# Events:
{:command_started, line}
{:output, chunk}
{:error, %Jido.Shell.Error{}}
{:cwd_changed, path}
:command_done
:command_cancelled
{:command_crashed, reason}
```

## Code Style

- Use `mix format` before committing
- Elixir naming: snake_case functions, PascalCase modules
- Pattern match with `{:ok, result}` | `{:error, reason}`
- Add `@spec` type annotations for public functions
- Test with ExUnit in `describe` blocks
- Use `Jido.Shell.Error` for structured errors
- Follow conventional commits for git messages

## Testing

```elixir
# Use Jido.Shell.TestShell for E2E tests
shell = Jido.Shell.TestShell.start!()
assert {:ok, "/"} = Jido.Shell.TestShell.run(shell, "pwd")
```

## File Structure

```
lib/
├── kodo.ex                    # Version and utilities
├── kodo/
│   ├── application.ex         # OTP application
│   ├── agent.ex               # Agent API
│   ├── session.ex             # Session management
│   ├── session_server.ex      # Session GenServer
│   ├── session/state.ex       # Session state struct
│   ├── command.ex             # Command behaviour
│   ├── command/               # Built-in commands
│   ├── command_runner.ex      # Task execution
│   ├── vfs.ex                 # Virtual filesystem
│   ├── vfs/                   # VFS internals
│   ├── transport/             # IEx and TermUI
│   └── error.ex               # Error handling
├── mix/tasks/
│   └── kodo.ex                # mix kodo task
test/
├── support/
│   ├── case.ex                # Test case template
│   └── test_shell.ex          # E2E test helper
├── kodo/
│   ├── e2e_test.exs           # End-to-end tests
│   └── ...                    # Unit tests
```
