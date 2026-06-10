# Jido.Shell Usage Rules for LLMs

This document provides guidance for LLMs using Jido.Shell for file and shell operations.

## Quick Reference

### Starting a Session

```elixir
# Create a session with in-memory VFS
{:ok, session} = Jido.Shell.Agent.new("my_workspace")
```

### Running Commands

```elixir
# Synchronous command execution
{:ok, output} = Jido.Shell.Agent.run(session, "ls")
{:ok, output} = Jido.Shell.Agent.run(session, "pwd")
{:ok, output} = Jido.Shell.Agent.run(session, "cat /path/to/file")

# Multiple commands
results = Jido.Shell.Agent.run_all(session, ["mkdir /dir", "cd /dir", "pwd"])
```

### Sandboxed Backends

```elixir
# Persistent sandboxed Bash
{:ok, bash_session} =
  Jido.Shell.Agent.new("my_workspace",
    backend: {Jido.Shell.Backend.Bash, %{}})

# Persistent sandboxed Lua VM
{:ok, lua_session} =
  Jido.Shell.Agent.new("my_workspace",
    backend: {Jido.Shell.Backend.Lua, %{}})

{:ok, output} =
  Jido.Shell.Agent.run(lua_session, ~S|jido.echo("hello", "lua")|)
```

Lua scripts must call registered commands through the `jido.*` namespace. Host
I/O, `require`, file loading, and `os.execute` are sandboxed by `Lua.new/0`;
filesystem access goes through bridged Jido commands and the VFS.

### File Operations

```elixir
# Write files
:ok = Jido.Shell.Agent.write_file(session, "/path/to/file.txt", "content")

# Read files
{:ok, content} = Jido.Shell.Agent.read_file(session, "/path/to/file.txt")

# List directory
{:ok, entries} = Jido.Shell.Agent.list_dir(session, "/path")
```

### Session State

```elixir
# Get current directory
cwd = Jido.Shell.Agent.cwd(session)

# Get full state
{:ok, state} = Jido.Shell.Agent.state(session)
```

### Cleanup

```elixir
# Always stop sessions when done
:ok = Jido.Shell.Agent.stop(session)
```

## Available Commands

| Command | Usage | Description |
|---------|-------|-------------|
| `echo` | `echo hello world` | Print text |
| `pwd` | `pwd` | Print working directory |
| `cd` | `cd /path` | Change directory |
| `ls` | `ls [path]` | List directory |
| `cat` | `cat file` | Display file contents |
| `write` | `write file content` | Write to file |
| `mkdir` | `mkdir dir` | Create directory |
| `rm` | `rm file` | Remove file |
| `cp` | `cp src dest` | Copy file |
| `env` | `env VAR=value` | Set environment variable |
| `bash` | `bash -c "script"` | Execute sandboxed Bash script |
| `help` | `help [cmd]` | Show help |

## Best Practices

1. **Use absolute paths** when possible to avoid ambiguity
2. **Check command results** - handle `{:error, _}` tuples appropriately
3. **Create directories** before writing files in them
4. **Stop sessions** when done to free resources
5. **Use `run_all`** for sequential operations that depend on each other

## Error Handling

```elixir
case Jido.Shell.Agent.run(session, "cat /missing.txt") do
  {:ok, output} -> handle_output(output)
  {:error, %Jido.Shell.Error{code: {:vfs, :not_found}}} -> handle_missing()
  {:error, error} -> handle_error(error)
end
```

## Common Error Codes

- `{:vfs, :not_found}` - File or directory not found
- `{:vfs, :not_directory}` - Expected directory, got file
- `{:shell, :unknown_command}` - Command not recognized
- `{:shell, :busy}` - Another command is running
- `{:command, :timeout}` - Command timed out
