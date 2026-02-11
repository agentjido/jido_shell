# Jido.Shell

[![Hex.pm](https://img.shields.io/hexpm/v/kodo.svg)](https://hex.pm/packages/kodo)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/kodo)
[![CI](https://github.com/agentjido/kodo/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/kodo/actions/workflows/ci.yml)

Virtual workspace shell for LLM-human collaboration in the AgentJido ecosystem.

Jido.Shell provides an Elixir-native virtual shell with an in-memory filesystem, streaming output, and both interactive and programmatic interfaces. It's designed for AI agents that need to manipulate files and run commands in isolated, sandboxed environments.

## Features

- **Virtual Filesystem** - In-memory VFS with [Hako](https://github.com/agentjido/hako) adapter support
- **Familiar Shell Interface** - Unix-like commands (ls, cd, cat, echo, etc.)
- **Streaming Output** - Real-time command output via pub/sub events
- **Session Management** - Multiple isolated sessions per workspace
- **Agent-Friendly API** - Simple synchronous interface for AI agents
- **Interactive Transports** - IEx REPL and rich terminal UI

## Installation

### Igniter Installation
If your project has [Igniter](https://hexdocs.pm/igniter/readme.html) available, 
you can install Jido Shell using the command 

```bash
mix igniter.install jido_shell
```

### Manual Installation

Add `jido_shell` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:jido_shell, "~> 1.0"}
  ]
end
```

## Quick Start

### Interactive Shell

```bash
# Start IEx-style shell
mix jido_shell

# Start with rich terminal UI
mix jido_shell --ui
```

### Programmatic Usage (Agent API)

```elixir
# Create a new session with in-memory VFS
{:ok, session} = Jido.Shell.Agent.new(:my_workspace)

# Run commands synchronously
{:ok, output} = Jido.Shell.Agent.run(session, "echo Hello World")
# => {:ok, "Hello World\n"}

{:ok, output} = Jido.Shell.Agent.run(session, "pwd")
# => {:ok, "/\n"}

# File operations
:ok = Jido.Shell.Agent.write_file(session, "/hello.txt", "Hello from Jido.Shell!")
{:ok, content} = Jido.Shell.Agent.read_file(session, "/hello.txt")
# => {:ok, "Hello from Jido.Shell!"}

# Directory operations
{:ok, _} = Jido.Shell.Agent.run(session, "mkdir /projects")
{:ok, _} = Jido.Shell.Agent.run(session, "cd /projects")
{:ok, entries} = Jido.Shell.Agent.list_dir(session, "/")

# Run multiple commands
results = Jido.Shell.Agent.run_all(session, ["mkdir /docs", "cd /docs", "pwd"])

# Clean up
:ok = Jido.Shell.Agent.stop(session)
```

### Low-Level Session API

For more control over session events:

```elixir
# Start a session with VFS
{:ok, session_id} = Jido.Shell.Session.start_with_vfs(:my_workspace)

# Subscribe to events
:ok = Jido.Shell.SessionServer.subscribe(session_id, self())

# Run commands (async, streams events)
:ok = Jido.Shell.SessionServer.run_command(session_id, "ls -la")

# Receive events
receive do
  {:kodo_session, ^session_id, {:output, chunk}} -> IO.write(chunk)
  {:kodo_session, ^session_id, :command_done} -> :done
end

# Cancel running command
:ok = Jido.Shell.SessionServer.cancel(session_id)

# Stop session
:ok = Jido.Shell.Session.stop(session_id)
```

## Available Commands

| Command                   | Description                           |
|---------------------------|---------------------------------------|
| `echo [args...]`          | Print arguments to output             |
| `pwd`                     | Print working directory               |
| `cd [path]`               | Change directory                      |
| `ls [path]`               | List directory contents               |
| `cat <file>`              | Display file contents                 |
| `write <file> <content>`  | Write content to file                 |
| `mkdir <dir>`             | Create directory                      |
| `rm <file>`               | Remove file                           |
| `cp <src> <dest>`         | Copy file                             |
| `env [VAR] [VAR=value]`   | Display or set environment variables  |
| `help [command]`          | Show available commands               |
| `sleep <seconds>`         | Sleep for duration                    |
| `seq <count> [delay]`     | Print sequence of numbers             |

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Transports                                                      │
│  • Jido.Shell.Transport.IEx (interactive shell in IEx)          │
│  • Jido.Shell.Transport.TermUI (rich terminal UI)               │
│  • Jido.Shell.Agent (programmatic API for agents)               │
└──────────────────────────┬──────────────────────────────────────┘
                           │ subscribe / run_command
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ Jido.Shell.SessionServer (GenServer per session)                │
│  • Holds session state (cwd, env, history)                      │
│  • Manages transport subscriptions                              │
│  • Spawns command tasks, broadcasts output                      │
└──────────────────────────┬──────────────────────────────────────┘
                           │ spawn Task under CommandTaskSupervisor
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ Jido.Shell.CommandRunner (Task process)                         │
│  • Executes command logic                                       │
│  • Streams output back to session                               │
└──────────────────────────┬──────────────────────────────────────┘
                           │ calls
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ Jido.Shell.Command modules (@behaviour Jido.Shell.Command)      │
│  • name/0, summary/0, schema/0                                  │
│  • run/3 (state, args, emit)                                    │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ Jido.Shell.VFS                                                  │
│  • Router + ETS mount table                                     │
│  • File operations over Hako adapters                           │
└─────────────────────────────────────────────────────────────────┘
```

## Creating Custom Commands

Implement the `Jido.Shell.Command` behaviour:

```elixir
defmodule MyApp.Command.Greet do
  @behaviour Jido.Shell.Command

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

| Event                             | Description                    |
|-----------------------------------|--------------------------------|
| `{:command_started, line}`        | Command execution began        |
| `{:output, chunk}`                | Streaming output chunk         |
| `{:error, Jido.Shell.Error.t()}`  | Error occurred                 |
| `{:cwd_changed, path}`            | Working directory changed      |
| `:command_done`                   | Command completed successfully |
| `:command_cancelled`              | Command was cancelled          |
| `{:command_crashed, reason}`      | Task terminated abnormally     |

## Mounting Local Filesystems

Jido.Shell can mount real directories using Hako adapters:

```elixir
# Mount a local directory
:ok = Jido.Shell.VFS.mount(:workspace, "/code", Hako.Adapter.Local, prefix: "/path/to/project")

# Start session - now /code maps to the real directory
{:ok, session} = Jido.Shell.Agent.new(:workspace)
{:ok, output} = Jido.Shell.Agent.run(session, "ls /code")
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

Apache-2.0 - see [LICENSE](LICENSE) for details.
