# Jido.Shell

[![Hex.pm](https://img.shields.io/hexpm/v/jido_shell.svg)](https://hex.pm/packages/jido_shell)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/jido_shell/)
[![CI](https://github.com/agentjido/jido_shell/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/jido_shell/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/jido_shell.svg)](https://github.com/agentjido/jido_shell/blob/main/LICENSE)
[![Website](https://img.shields.io/badge/website-jido.run-0f172a.svg)](https://jido.run)
[![Ecosystem](https://img.shields.io/badge/ecosystem-jido.run-0ea5e9.svg)](https://jido.run/ecosystem)
[![Discord](https://img.shields.io/badge/discord-join-5865F2.svg?logo=discord&logoColor=white)](https://jido.run/discord)

Virtual workspace shell for LLM-human collaboration in the AgentJido ecosystem.

Jido.Shell provides an Elixir-native virtual shell with in-memory filesystems, streaming output, structured errors, and synchronous agent-friendly APIs.

## Features

- Virtual filesystem with [Jido.VFS](https://github.com/agentjido/jido_vfs) adapter support
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
{:ok, session_id} = Jido.Shell.ShellSession.start_with_vfs("my_workspace")
{:ok, :subscribed} = Jido.Shell.ShellSessionServer.subscribe(session_id, self())

{:ok, :accepted} = Jido.Shell.ShellSessionServer.run_command(session_id, "echo hi")

receive do
  {:jido_shell_session, ^session_id, {:output, chunk}} -> IO.write(chunk)
  {:jido_shell_session, ^session_id, :command_done} -> :ok
end

{:ok, :cancelled} = Jido.Shell.ShellSessionServer.cancel(session_id)
:ok = Jido.Shell.ShellSession.stop(session_id)
```

### Session Module Naming

Canonical session modules are:

- `Jido.Shell.ShellSession`
- `Jido.Shell.ShellSessionServer`
- `Jido.Shell.ShellSession.State`

## Execution Backends

Sessions run with `Jido.Shell.Backend.Local` by default.

### Bash Backend

The Bash backend hands entire command lines to a persistent `Bash.Session` process, so loops, conditionals, variables, pipes, and arithmetic expansion all work as in real Bash. State persists across calls within the same session.

The Bash backend currently depends on upstream `tv-labs/bash` changes that are
newer than the latest Hex release. Until those changes are published, the Bash
backend is available from source/Git builds and is excluded from the Hex
package.

```elixir
{:bash,
 git: "https://github.com/tv-labs/bash.git",
 ref: "c1038ff83e825c29ea131bf8b728bd1672734c01"}
```

**Starting a session:**

```elixir
{:ok, session_id} =
  Jido.Shell.ShellSession.start_with_vfs("my_workspace",
    backend: {Jido.Shell.Backend.Bash, %{}}
  )
```

**Agent API:**

```elixir
{:ok, session} = Jido.Shell.Agent.new("my_workspace",
  backend: {Jido.Shell.Backend.Bash, %{}})

{:ok, output} = Jido.Shell.Agent.run(session, """
  for i in 1 2 3; do echo "item $i"; done
""")
```

**IEx transport:**

```elixir
Jido.Shell.Transport.IEx.start("my_workspace",
  backend: {Jido.Shell.Backend.Bash, %{}})
```

All registered Jido commands (`echo`, `ls`, `cat`, `cd`, `write`, etc.) are bridged into bash via function shims, so scripts can call them by name. Filesystem I/O routes through `Jido.Shell.VFS` — no host files are touched.

**Isolation:** External binaries (`grep`, `sed`, `curl`, etc.) are blocked by command policy. The session environment is sanitised — `HOME`, `PATH`, and `MACHTYPE` are overridden with sandbox-safe values. See `Jido.Shell.Backend.Bash` moduledoc for the full isolation model.

**Known limitations:**

- Only bash builtins and bridged Jido commands are available — no host binaries.
- Glob support covers simple `*`/`?` patterns only.
- Cancellation uses `Bash.Session.signal/3` with `:sigint`; scripts can run `INT`/`EXIT` traps before stopping.

### Lua Backend

The Lua backend runs scripts in the pure-Elixir `:lua` VM. Lua globals and functions persist across calls within the same session, and registered Jido commands are available under the explicit `jido.*` namespace.

The Lua backend is included in the Hex package and uses the required pure-Elixir
`:lua` dependency.

**Starting a session:**

```elixir
{:ok, session_id} =
  Jido.Shell.ShellSession.start_with_vfs("my_workspace",
    backend: {Jido.Shell.Backend.Lua, %{}}
  )
```

**Agent API:**

```elixir
{:ok, session} = Jido.Shell.Agent.new("my_workspace",
  backend: {Jido.Shell.Backend.Lua, %{}})

{:ok, output} = Jido.Shell.Agent.run(session, """
  jido.echo("hello", "lua")
  x = 5
  print(x)
""")
```

**Isolation:** `Lua.new/0` sandboxes host access by default. `io`, file loading, `require`, package loading, `os.execute`, `os.exit`, and `os.getenv` are disabled. File access is only available through bridged Jido commands such as `jido.cat`, `jido.write`, and `jido.ls`, which route through `Jido.Shell.VFS`.

**Known limitations:**

- Use `jido.echo`, `jido.ls`, etc.; bare command aliases are not installed.
- `configure_network/2` is a no-op because the Lua VM exposes no network primitives.
- Runtime and output limits are enforced by killing the eval worker; the persistent Lua holder remains reusable after timeout or cancellation.

### Sprite Backend

To execute commands on Fly.io Sprites, pass a backend tuple when starting a session:

```elixir
{:ok, session_id} =
  Jido.Shell.ShellSession.start_with_vfs("my_workspace",
    backend:
      {Jido.Shell.Backend.Sprite,
       %{
         sprite_name: "my-agent-session",
         token: System.fetch_env!("SPRITES_TOKEN"),
         create: true
       }}
  )
```

Use `create: true` for ephemeral session Sprites and `create: false` to connect to an existing Sprite by name.

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
- `{:output_stderr, chunk}`
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

## Package Purpose

`jido_shell` is the shell/session execution layer for Jido, including backend abstraction (local/sprite), command execution helpers, and shell-side runtime tooling.

## Testing Paths

- Unit/integration-lite tests: `mix test`
- Full quality gate: `mix quality`
- Optional flaky cases: `mix test --include flaky`
