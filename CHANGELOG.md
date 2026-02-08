# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.0.0] - 2024-12-23

### Added
- Complete v3 reimplementation from scratch
- `Jido.Shell.Session` - Session management with Registry and DynamicSupervisor
- `Jido.Shell.SessionServer` - GenServer per session with state and subscriptions
- `Jido.Shell.Command` behaviour - Unified command interface with streaming support
- `Jido.Shell.CommandRunner` - Task-based command execution
- `Jido.Shell.VFS` - Virtual filesystem with Hako adapters and mount table
- `Jido.Shell.Agent` - Agent-friendly programmatic API
- `Jido.Shell.Transport.IEx` - Interactive IEx shell transport
- `Jido.Shell.Transport.TermUI` - Rich terminal UI transport
- Built-in commands: echo, pwd, cd, ls, cat, write, mkdir, rm, cp, env, help, sleep, seq
- `mix kodo` task for easy shell access
- Zoi schema validation for command arguments
- Structured errors with `Jido.Shell.Error`
- Session events protocol for streaming output
- Command cancellation support

### Changed
- Complete architecture redesign for streaming and agent integration
- GenServer-based sessions replace stateless execution

### Removed
- Legacy v2 implementation
