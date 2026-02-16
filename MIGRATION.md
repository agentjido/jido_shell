# Migration Guide

This guide covers migration to the V1 hardening surface for `jido_shell`.

## 1. Workspace IDs Are Strings

`workspace_id` is now `String.t()` across public APIs.

### Before

```elixir
{:ok, session_id} = Jido.Shell.Session.start(:my_workspace)
```

### After

```elixir
{:ok, session_id} = Jido.Shell.Session.start("my_workspace")
```

Invalid workspace identifiers now return structured errors:

```elixir
{:error, %Jido.Shell.Error{code: {:session, :invalid_workspace_id}}}
```

## 2. SessionServer APIs Return Explicit Result Tuples

`Jido.Shell.SessionServer` APIs now return explicit success/error tuples and do not crash callers on missing sessions.

### Updated return shapes

- `subscribe/3` -> `{:ok, :subscribed} | {:error, Jido.Shell.Error.t()}`
- `unsubscribe/2` -> `{:ok, :unsubscribed} | {:error, Jido.Shell.Error.t()}`
- `get_state/1` -> `{:ok, Jido.Shell.Session.State.t()} | {:error, Jido.Shell.Error.t()}`
- `run_command/3` -> `{:ok, :accepted} | {:error, Jido.Shell.Error.t()}`
- `cancel/1` -> `{:ok, :cancelled} | {:error, Jido.Shell.Error.t()}`

## 3. Agent APIs Preserve Tuple Semantics and Return Structured Errors

`Jido.Shell.Agent` now returns typed errors for missing/invalid sessions instead of allowing process exits to leak.

### Example

```elixir
{:error, %Jido.Shell.Error{code: {:session, :not_found}}} =
  Jido.Shell.Agent.run("missing-session", "echo hi")
```

## 4. Interactive CLI Surface Is IEx-Only

The V1 surface supports:

- `mix jido_shell`
- `Jido.Shell.Transport.IEx`

The alternate rich UI mode is no longer part of the public release surface.

## 5. Command Parsing and Chaining Semantics

Top-level chaining is supported outside `bash`:

- `;` always continues
- `&&` short-circuits on error

Examples:

```text
echo one; echo two
mkdir /tmp && cd /tmp && pwd
```

Parser behavior is now quote/escape aware and returns structured syntax errors for malformed input.

## 6. Command Validation and Execution Limits

Numeric commands (`sleep`, `seq`) now return validation errors for invalid values instead of crashing.

Optional execution limits can be passed through `execution_context`:

```elixir
execution_context: %{
  limits: %{
    max_runtime_ms: 5_000,
    max_output_bytes: 50_000
  }
}
```

## 7. Network Policy Defaults

Sandboxed network-style commands are denied by default.

Allow access per command via `execution_context.network` allowlists (domains/ports).

## 8. Session Event Tuple

Session events are emitted as:

```elixir
{:jido_shell_session, session_id, event}
```

