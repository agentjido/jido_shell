# Jido.Shell

[![Hex.pm](https://img.shields.io/hexpm/v/jido_shell.svg)](https://hex.pm/packages/jido_shell)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/jido_shell)
[![CI](https://github.com/agentjido/jido_shell/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/jido_shell/actions/workflows/ci.yml)

Virtual workspace shell for LLM-human collaboration in the AgentJido ecosystem.

Jido.Shell provides an Elixir-native virtual shell with in-memory filesystems, streaming output, structured errors, and synchronous agent-friendly APIs.

## Features

- Virtual filesystem with [Jido.VFS](https://github.com/agentjido/hako) adapter support
- Unix-like built-in commands (`ls`, `cd`, `cat`, `write`, `rm`, `cp`, `env`, `bash`)
- Session-scoped state (`cwd`, env vars, history)
- Streaming session events (`{:jido_shell_session, session_id, event}`)
- Top-level command chaining: `;` (always continue), `&&` (short-circuit on error)
- Per-command sandbox controls for network and execution limits

## Installation

### Igniter

```bash
mix igniter.install jido_shell
```

### Manual

```elixir
def deps do
  [
    {:jido_shell, "~> 3.0"}
  ]
end
```

## Quick Start

### Interactive Shell

```bash
mix jido_shell
mix jido_shell --workspace my_workspace
```

### Agent API

```elixir
{:ok, session} = Jido.Shell.Agent.new("my_workspace")

{:ok, "Hello\n"} = Jido.Shell.Agent.run(session, "echo Hello")
{:ok, "/\n"} = Jido.Shell.Agent.run(session, "pwd")

:ok = Jido.Shell.Agent.write_file(session, "/hello.txt", "world")
{:ok, "world"} = Jido.Shell.Agent.read_file(session, "/hello.txt")

{:ok, "/"} = Jido.Shell.Agent.cwd(session)
:ok = Jido.Shell.Agent.stop(session)
```

### Low-Level Session API

```elixir
{:ok, session_id} = Jido.Shell.Session.start_with_vfs("my_workspace")
{:ok, :subscribed} = Jido.Shell.SessionServer.subscribe(session_id, self())

{:ok, :accepted} = Jido.Shell.SessionServer.run_command(session_id, "echo hi")

receive do
  {:jido_shell_session, ^session_id, {:output, chunk}} -> IO.write(chunk)
  {:jido_shell_session, ^session_id, :command_done} -> :ok
end

{:ok, :cancelled} = Jido.Shell.SessionServer.cancel(session_id)
:ok = Jido.Shell.Session.stop(session_id)
```

## Command Chaining

Jido.Shell supports top-level chaining outside `bash`:

- `;` always runs the next command.
- `&&` runs the next command only if the previous command succeeded.

Examples:

```text
echo one; echo two
mkdir /tmp && cd /tmp && pwd
```

## Bash Sandbox

`bash -c "..."` executes scripts through registered Jido.Shell commands (not the host shell).

Network-style commands are denied by default. Allow per command with `execution_context.network`:

```elixir
Jido.Shell.Agent.run(
  session,
  "bash -c \"curl https://example.com:8443\"",
  execution_context: %{
    network: %{
      allow_domains: ["example.com"],
      allow_ports: [8443]
    }
  }
)
```

Optional execution limits are supported through `execution_context.limits`:

```elixir
Jido.Shell.Agent.run(
  session,
  "seq 10000 0",
  execution_context: %{
    limits: %{
      max_runtime_ms: 5_000,
      max_output_bytes: 50_000
    }
  }
)
```

## Available Commands

| Command | Description |
|---|---|
| `echo [args...]` | Print arguments |
| `pwd` | Print working directory |
| `cd [path]` | Change directory |
| `ls [path]` | List directory contents |
| `cat <file>` | Display file contents |
| `write <file> <content>` | Write file |
| `mkdir <dir>` | Create directory |
| `rm <file...>` | Remove files |
| `cp <src> <dest>` | Copy file |
| `env [VAR] [VAR=value]` | Get/set environment variables |
| `bash -c "<script>"` / `bash <file>` | Execute sandboxed script |
| `sleep [seconds]` | Sleep (for cancellation testing) |
| `seq [count] [delay_ms]` | Emit numeric sequence |
| `help [command]` | Show help |

## Session Events

Events are published as:

```elixir
{:jido_shell_session, session_id, event}
```

Event payloads:

- `{:command_started, line}`
- `{:output, chunk}`
- `{:error, %Jido.Shell.Error{}}`
- `{:cwd_changed, path}`
- `:command_done`
- `:command_cancelled`
- `{:command_crashed, reason}`

## Local Filesystem Mounts

```elixir
:ok = Jido.Shell.VFS.mount("workspace", "/code", Jido.VFS.Adapter.Local, prefix: "/path/to/project")

{:ok, session} = Jido.Shell.Agent.new("workspace")
{:ok, output} = Jido.Shell.Agent.run(session, "ls /code")
```

## Breaking Changes in V1 Hardening

Major V1 hardening changes are documented in [MIGRATION.md](MIGRATION.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache-2.0. See [LICENSE](LICENSE).
