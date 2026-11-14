# Shell v3 compatibility result

Starting branch: `main`. Starting revision: `f2addc04ca620078f74885cb71f10a7cd29f763e`.
The primary branch was retained to preserve local and concurrent work.
The delivery report names the exact published branch and commit.

Status: checked v3 source candidate.

## Boundary and implementation

The runtime has no core dependency. `Jido.Shell.Agent` is a synchronous Shell
session facade, not a core Agent implementation. Session string IDs, tuple
results, and session event messages stay unchanged. The migration guide now
states the supported v3 host boundary. No runtime code change was required.
The existing sibling VFS path setup is intentional and stays in place.

## Checks

- `mix test`: 670 passed, 3 excluded by the standard flaky exclusion.
- `mix quality`: passed, including guardrails and Dialyzer.
- Workspace's 27 deterministic v3 boundary tests passed with this Shell source.
- Isolated Jidoka: 4 focused tests passed; see shared evidence.
- Local `mix hex.build` refuses the sibling path dependency. A standalone source copy at `/private/tmp/five-v3/shell-standalone`, with no sibling checkout, passes `mix hex.build` through its existing Hex VFS fallback.
- Hex reports VFS 1.0.1 as the latest release on this date. The standalone released-graph check also passed 670 tests, with 3 standard exclusions, using VFS 1.0.1 from Hex.

Workspace is the direct package consumer. Its resource, policy, shell command,
and capture checks exercised the current VFS/Shell/Workspace chain. Live Bash,
Sprite, SSH, and provider environments were not part of the v3 consumer check.

## Shared evidence and limits

Date: 2026-11-14. GitHub API checks confirmed consolidated core `release/v3`
at `047bf746330a2fbe7c3b25c045552e0303c97eaf`. Tests used Elixir 1.20.4,
OTP 29.1.2. Core owns Action, Signal, and AI modules. No separate legacy
core package is present in either new consumer fixture dependency tree.
No mandatory core runtime dependency was added to a standalone package.

The package sources and consumer fixtures were self-checked. A separate source
review checked the Harness reconciliation. No live model or paid provider
check ran. No live app home, checkpoint, or database was changed.

Jidoka started on `release/v3` at
`5b697d3d3a0f96bc7baf063687d4a98f31a0565a`, with local checkpoint work.
Its source was copied to `/private/tmp/five-v3/jidoka`. Only that copy's
manifest used paths to the four candidate libraries. Core remained pinned to
`047bf746`. The command below passed 4 tests with a temporary SQLite database:

```sh
MIX_TARGET=desktop ERL_FLAGS='+S 4:4' mix test test/jidoka/workspaces_test.exs test/jidoka/inference/detector_test.exs
```

The first two tests cover write/read/list/capture, mutation policy, storage
selection refusal, and close. The other two cover provider discovery and
failure normalization. They do not run a live Harness provider. The original
Jidoka checkout and its existing local changes were preserved.

## Release order

Publish the required consolidated core and shared dependencies first. ReqLLM
1.30.0 and Zoi 0.19.0 are already available. Release VFS before Shell, then
Workspace, then update and check Jidoka dependency pins. Character and Harness
can release independently after their shared dependencies are available.
Migrate Hancho before claiming it supports the new Harness candidate. No
registry publication, release, merge, or PR was part of this work.

## Static config audit

From the primary source directory, `mix credo --strict --config-file .credo.exs`
passed with 65 checks. This explicitly selects the repository config and
avoids temporary-directory config ancestry. The shared `/private/tmp/.credo.exs`
was not changed.
