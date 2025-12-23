# Kodo Usage Rules for LLMs

This document provides guidance for LLMs using Kodo for file and shell operations.

## Quick Reference

### Starting a Session

```elixir
# Create a session with in-memory VFS
{:ok, session} = Kodo.Agent.new(:my_workspace)
```

### Running Commands

```elixir
# Synchronous command execution
{:ok, output} = Kodo.Agent.run(session, "ls")
{:ok, output} = Kodo.Agent.run(session, "pwd")
{:ok, output} = Kodo.Agent.run(session, "cat /path/to/file")

# Multiple commands
results = Kodo.Agent.run_all(session, ["mkdir /dir", "cd /dir", "pwd"])
```

### File Operations

```elixir
# Write files
:ok = Kodo.Agent.write_file(session, "/path/to/file.txt", "content")

# Read files
{:ok, content} = Kodo.Agent.read_file(session, "/path/to/file.txt")

# List directory
{:ok, entries} = Kodo.Agent.list_dir(session, "/path")
```

### Session State

```elixir
# Get current directory
cwd = Kodo.Agent.cwd(session)

# Get full state
{:ok, state} = Kodo.Agent.state(session)
```

### Cleanup

```elixir
# Always stop sessions when done
:ok = Kodo.Agent.stop(session)
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
| `help` | `help [cmd]` | Show help |

## Best Practices

1. **Use absolute paths** when possible to avoid ambiguity
2. **Check command results** - handle `{:error, _}` tuples appropriately
3. **Create directories** before writing files in them
4. **Stop sessions** when done to free resources
5. **Use `run_all`** for sequential operations that depend on each other

## Error Handling

```elixir
case Kodo.Agent.run(session, "cat /missing.txt") do
  {:ok, output} -> handle_output(output)
  {:error, %Kodo.Error{code: {:vfs, :not_found}}} -> handle_missing()
  {:error, error} -> handle_error(error)
end
```

## Common Error Codes

- `{:vfs, :not_found}` - File or directory not found
- `{:vfs, :not_directory}` - Expected directory, got file
- `{:shell, :unknown_command}` - Command not recognized
- `{:shell, :busy}` - Another command is running
- `{:command, :timeout}` - Command timed out
