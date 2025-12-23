# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.0.0] - 2024-12-23

### Added
- Complete v3 reimplementation from scratch
- `Kodo.Session` - Session management with Registry and DynamicSupervisor
- `Kodo.SessionServer` - GenServer per session with state and subscriptions
- `Kodo.Command` behaviour - Unified command interface with streaming support
- `Kodo.CommandRunner` - Task-based command execution
- `Kodo.VFS` - Virtual filesystem with Hako adapters and mount table
- `Kodo.Agent` - Agent-friendly programmatic API
- `Kodo.Transport.IEx` - Interactive IEx shell transport
- `Kodo.Transport.TermUI` - Rich terminal UI transport
- Built-in commands: echo, pwd, cd, ls, cat, write, mkdir, rm, cp, env, help, sleep, seq
- `mix kodo` task for easy shell access
- Zoi schema validation for command arguments
- Structured errors with `Kodo.Error`
- Session events protocol for streaming output
- Command cancellation support

### Changed
- Complete architecture redesign for streaming and agent integration
- GenServer-based sessions replace stateless execution

### Removed
- Legacy v2 implementation
