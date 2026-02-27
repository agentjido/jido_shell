# Agent Guide for Jido.Shell

## Purpose

Jido.Shell is an Elixir-native virtual shell for multi-session, sandboxed command execution over virtual filesystems.

## Key Commands

```bash
mix setup
mix compile --warnings-as-errors
mix test
mix test --include flaky
mix coveralls
mix jido_shell.guardrails
mix quality
mix docs
mix jido_shell
```

## Core Architecture

```
Jido.Shell.Supervisor
├── Jido.Shell.VFS.MountTable
├── Registry (Jido.Shell.SessionRegistry)
├── DynamicSupervisor (Jido.Shell.SessionSupervisor)
├── DynamicSupervisor (Jido.Shell.FilesystemSupervisor)
└── Task.Supervisor (Jido.Shell.CommandTaskSupervisor)
```

## Main Modules

- `Jido.Shell.Agent` - synchronous API for agents
- `Jido.Shell.ShellSession` - session lifecycle
- `Jido.Shell.ShellSessionServer` - per-session GenServer
- `Jido.Shell.ShellSession.State` - canonical session state struct
- `Jido.Shell.CommandRunner` - command execution and chaining
- `Jido.Shell.VFS` - mounted filesystem router
- `Jido.Shell.Transport.IEx` - interactive shell transport

Deprecated compatibility shims: `Jido.Shell.Session`, `Jido.Shell.SessionServer`, `Jido.Shell.Session.State`.

## Session Events

```elixir
{:jido_shell_session, session_id, event}
```

Events:

- `{:command_started, line}`
- `{:output, chunk}`
- `{:error, %Jido.Shell.Error{}}`
- `{:cwd_changed, path}`
- `:command_done`
- `:command_cancelled`
- `{:command_crashed, reason}`

## Test Layout

- Unit/integration: `test/jido/shell/**/*.exs`
- End-to-end: `test/jido/shell/e2e_test.exs`
- Support helpers: `test/support/*.ex`

## Conventions

- Prefer tuple-based APIs: `{:ok, ...}` / `{:error, ...}`
- Use `Jido.Shell.Error` for structured errors
- Keep workspace IDs as strings (`String.t()`)
- Avoid runtime atom generation from user input
