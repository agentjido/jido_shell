# Kodo

[![Hex.pm](https://img.shields.io/hexpm/v/kodo.svg)](https://hex.pm/packages/kodo)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/kodo)
[![CI](https://github.com/agentjido/kodo/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/kodo/actions/workflows/ci.yml)

Virtual workspace shell for LLM-human collaboration in the AgentJido ecosystem.

Kodo provides an Elixir-native virtual shell with an in-memory filesystem, streaming output, and both interactive and programmatic interfaces. It's designed for AI agents that need to manipulate files and run commands in isolated, sandboxed environments.

## Features

- **Virtual Filesystem** - In-memory VFS with [Depot](https://github.com/elixir-depot/depot) adapter support
- **Familiar Shell Interface** - Unix-like commands (ls, cd, cat, echo, etc.)
- **Streaming Output** - Real-time command output via pub/sub events
- **Session Management** - Multiple isolated sessions per workspace
- **Agent-Friendly API** - Simple synchronous interface for AI agents
- **Interactive Transports** - IEx REPL and rich terminal UI

## Installation

Add `kodo` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:kodo, "~> 3.0"}
  ]
end
```

## Quick Start

### Interactive Shell

```bash
# Start IEx-style shell
mix kodo

# Start with rich terminal UI
mix kodo --ui
```

### Programmatic Usage (Agent API)

```elixir
# Create a new session with in-memory VFS
{:ok, session} = Kodo.Agent.new(:my_workspace)

# Run commands synchronously
{:ok, output} = Kodo.Agent.run(session, "echo Hello World")
# => {:ok, "Hello World\n"}

{:ok, output} = Kodo.Agent.run(session, "pwd")
# => {:ok, "/\n"}

# File operations
:ok = Kodo.Agent.write_file(session, "/hello.txt", "Hello from Kodo!")
{:ok, content} = Kodo.Agent.read_file(session, "/hello.txt")
# => {:ok, "Hello from Kodo!"}

# Directory operations
{:ok, _} = Kodo.Agent.run(session, "mkdir /projects")
{:ok, _} = Kodo.Agent.run(session, "cd /projects")
{:ok, entries} = Kodo.Agent.list_dir(session, "/")

# Run multiple commands
results = Kodo.Agent.run_all(session, ["mkdir /docs", "cd /docs", "pwd"])

# Clean up
:ok = Kodo.Agent.stop(session)
```

### Low-Level Session API

For more control over session events:

```elixir
# Start a session with VFS
{:ok, session_id} = Kodo.Session.start_with_vfs(:my_workspace)

# Subscribe to events
:ok = Kodo.SessionServer.subscribe(session_id, self())

# Run commands (async, streams events)
:ok = Kodo.SessionServer.run_command(session_id, "ls -la")

# Receive events
receive do
  {:kodo_session, ^session_id, {:output, chunk}} -> IO.write(chunk)
  {:kodo_session, ^session_id, :command_done} -> :done
end

# Cancel running command
:ok = Kodo.SessionServer.cancel(session_id)

# Stop session
:ok = Kodo.Session.stop(session_id)
```

## Available Commands

| Command | Description |
|---------|-------------|
| `echo [args...]` | Print arguments to output |
| `pwd` | Print working directory |
| `cd [path]` | Change directory |
| `ls [path]` | List directory contents |
| `cat <file>` | Display file contents |
| `write <file> <content>` | Write content to file |
| `mkdir <dir>` | Create directory |
| `rm <file>` | Remove file |
| `cp <src> <dest>` | Copy file |
| `env [VAR] [VAR=value]` | Display or set environment variables |
| `help [command]` | Show available commands |
| `sleep <seconds>` | Sleep for duration |
| `seq <count> [delay]` | Print sequence of numbers |

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Transports                                                      │
│  • Kodo.Transport.IEx (interactive shell in IEx)                │
│  • Kodo.Transport.TermUI (rich terminal UI)                     │
│  • Kodo.Agent (programmatic API for agents)                     │
└──────────────────────────┬──────────────────────────────────────┘
                           │ subscribe / run_command
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ Kodo.SessionServer (GenServer per session)                      │
│  • Holds session state (cwd, env, history)                      │
│  • Manages transport subscriptions                              │
│  • Spawns command tasks, broadcasts output                      │
└──────────────────────────┬──────────────────────────────────────┘
                           │ spawn Task under CommandTaskSupervisor
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ Kodo.CommandRunner (Task process)                               │
│  • Executes command logic                                       │
│  • Streams output back to session                               │
└──────────────────────────┬──────────────────────────────────────┘
                           │ calls
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ Kodo.Command modules (@behaviour Kodo.Command)                  │
│  • name/0, summary/0, schema/0                                  │
│  • run/3 (state, args, emit)                                    │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ Kodo.VFS                                                        │
│  • Router + ETS mount table                                     │
│  • File operations over Depot adapters                          │
└─────────────────────────────────────────────────────────────────┘
```

## Creating Custom Commands

Implement the `Kodo.Command` behaviour:

```elixir
defmodule MyApp.Command.Greet do
  @behaviour Kodo.Command

  @impl true
  def name, do: "greet"

  @impl true
  def summary, do: "Greet someone"

  @impl true
  def schema do
    Zoi.map(%{
      args: Zoi.array(Zoi.string()) |> Zoi.default([])
    })
  end

  @impl true
  def run(_state, args, emit) do
    name = Enum.join(args.args, " ") || "World"
    emit.({:output, "Hello, #{name}!\n"})
    {:ok, nil}
  end
end
```

## Session Events

When subscribed to a session, you receive these events:

| Event | Description |
|-------|-------------|
| `{:command_started, line}` | Command execution began |
| `{:output, chunk}` | Streaming output chunk |
| `{:error, Kodo.Error.t()}` | Error occurred |
| `{:cwd_changed, path}` | Working directory changed |
| `:command_done` | Command completed successfully |
| `:command_cancelled` | Command was cancelled |
| `{:command_crashed, reason}` | Task terminated abnormally |

## Mounting Local Filesystems

Kodo can mount real directories using Depot adapters:

```elixir
# Mount a local directory
:ok = Kodo.VFS.mount(:workspace, "/code", Depot.Adapter.Local, prefix: "/path/to/project")

# Start session - now /code maps to the real directory
{:ok, session} = Kodo.Agent.new(:workspace)
{:ok, output} = Kodo.Agent.run(session, "ls /code")
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

Apache-2.0 - see [LICENSE](LICENSE) for details.
