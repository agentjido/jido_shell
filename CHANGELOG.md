# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Renamed session namespace to explicit shell session modules:
  - `Jido.Shell.ShellSession`,
  - `Jido.Shell.ShellSessionServer`,
  - `Jido.Shell.ShellSession.State`.
- Kept `Jido.Shell.Session`, `Jido.Shell.SessionServer`, and `Jido.Shell.Session.State` as deprecated compatibility shims.
- Canonicalized state struct identity to `%Jido.Shell.ShellSession.State{}`.
- Hardened identifier model to use binary workspace IDs across public APIs.
- Removed runtime-generated atom usage from session/VFS workflows.
- Updated `SessionServer` and `Agent` APIs to return explicit structured errors for missing sessions and invalid identifiers instead of crashing callers.
- Added deterministic mount lifecycle behavior:
  - duplicate mount path rejection,
  - typed mount startup failures,
  - owned filesystem process termination on unmount/workspace teardown.
- Added workspace teardown API wiring for deterministic resource cleanup.
- Upgraded command parsing to support quote/escape-aware tokenization and top-level chaining (`;`, `&&`).
- Hardened `sleep` and `seq` argument parsing to return validation errors for invalid numerics.
- Expanded sandbox network policy endpoint handling and chaining-aware enforcement.
- Added optional per-command runtime/output limits in execution context.
- Removed the alternate rich UI mode from the V1 public release surface and CLI flags.
- Updated docs and examples to current names/event tuples and current package surface.

### Added
- `MIGRATION.md` documenting V1-facing breaking API changes and upgrade steps.
- New hardening tests for:
  - workspace identifier validation and atom leak regression,
  - session API resilience/error shaping,
  - mount lifecycle/cleanup behavior,
  - parser/chaining behavior and syntax errors,
  - command numeric validation,
  - network policy edge cases,
  - transport and helper branch behavior.
- CI coverage job with enforced coverage gate.

## [3.0.0] - 2024-12-23

### Added
- Complete v3 reimplementation from scratch.
- `Jido.Shell.Session`, `Jido.Shell.SessionServer`, `Jido.Shell.Command`, `Jido.Shell.CommandRunner`, `Jido.Shell.VFS`, `Jido.Shell.Agent`, `Jido.Shell.Transport.IEx`.
- Built-in commands: `echo`, `pwd`, `cd`, `ls`, `cat`, `write`, `mkdir`, `rm`, `cp`, `env`, `help`, `sleep`, `seq`.
- Structured shell errors and session event protocol.

### Changed
- Architecture redesign for streaming and agent integration.

### Removed
- Legacy v2 implementation.
