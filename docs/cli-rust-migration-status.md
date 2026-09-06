# Rust CLI migration living status

Last updated: 2026-09-06

This file is the running completion record for the Swift-to-Rust macOS CLI
migration. Update it after every implementation slice, test run, packaging
change, or decision that changes the cutover risk. The parity checker and this
document must agree. A passing Rust test subset is not completion.

## Goal

Ship one Rust implementation that gives end users the same `cmux` behavior as
the current Swift CLI, including command parsing, aliases, help, socket bytes,
authentication, output, exit codes, environment, files, side effects,
packaging, and release behavior. Keep one authentication authority for cmux
and CodeRouter. Ship CodeRouter both as `cmux cr` and as a separate
`coderouter` executable. Remove the Swift CLI only after the complete parity
gate passes and the final bundle size is measured.

## Completion rule

The migration is complete only when all of these are true:

1. The source-derived inventory covers every Swift dispatch arm and command
   label, with no stale source hash.
2. Every family in `docs/cli-rust-parity-manifest.json` is `complete`.
3. Dual-run conformance tests prove matching argv parsing, aliases, help,
   request method and parameters, output, stderr, exit status, environment,
   files, and side effects.
4. Rust matches Swift socket startup, marker discovery, password and keychain
   lookup, framing, timeouts, structured errors, and no-socket behavior.
5. A full macOS release build, install test, signing step, and end-user smoke
   test pass. `cmux cr add codex` works without a second login, and standalone
   `coderouter` works with the cmux broker and in its upstream fallback mode.
6. The Swift CLI is removed from the shipped app and the resulting bundle is
   measured against the current release.

An expert release engineer would reject a cutover before these checks. A
protocol request that looks similar is not proof of observable parity.

## Current state

**Status: in progress. Cutover blocked.**

The gate currently reports 126 Swift dispatch arms and 156 command labels.
All 12 families remain incomplete:

| Family | Status | Main missing evidence |
| --- | --- | --- |
| startup | partial | complete help, version, offline and no-socket behavior |
| socket-transport | partial | keychain fallback, all marker variants, timeout/error parity |
| coderouter-native | partial | all account verbs and Swift output/error parity |
| coderouter-delegated | partial | complete delegation and broker lifecycle parity |
| coderouter-team | pending | status, machines, Claude team operations |
| app-and-settings | pending | docs, settings, config, themes, auth, open, feedback |
| topology | partial | window inspection and basic window actions are ported; workspace, pane, surface, tree, and tab actions remain |
| terminal-and-notifications | pending | terminal I/O, feed, notifications, logs |
| browser | pending | browser commands, snapshots, actions, storage, profiles |
| agents-and-hooks | pending | hooks, teams, extensions, restore and feed paths |
| cloud-and-remotes | pending | VM, cloud, remote, SSH, and remote terminal paths |
| compatibility | pending | tmux compatibility and hidden agent commands |

The Rust candidate currently provides the migration slice for capabilities,
context, RPC, ping, identify, window inspection and basic window actions,
limited AI accounts, `cr add codex`, and CodeRouter delegation.
The Rust candidate binaries are about 1.375 MiB each as universal Mach-O
artifacts. Keeping Swift in production while the gate is red adds about
2.62 MiB. Removing Swift before the gate passes would risk breaking commands,
so that temporary size increase is accepted until cutover.

Known implementation gap: Rust auth resolution currently supports an explicit
password, `CMUX_SOCKET_PASSWORD`, and the shared password file. macOS Keychain
fallback still needs an implementation and a conformance test.

Known verification gap: the full Xcode release build and installed end-user
test have not run in this environment. The local build guard requires more
free disk than is available, and no usable xcodebuild MCP tool was exposed.

## Verification record

The following checks passed for the current slice:

- Rust format check.
- Clippy with warnings denied.
- `cargo test -p cmux-cli` (14 tests).
- V1 socket tests for `ping`, window inspection parsing, and window command
  dispatch.
- Identifier rendering tests for `refs`, `uuids`, and `both` modes.
- Universal arm64 and x86_64 Rust builds.
- CodeRouter broker, marker discovery, installer, and release-strip smoke
  tests.
- `cmux cr add codex` sends `aiAccounts.upload` with no credential in argv or
  socket parameters.

The authoritative gate command is:

```sh
python3 scripts/check-cli-rust-parity.py
```

It must exit `0` before production cutover. At the last update it exits `3`
because all 12 families are incomplete.

## Work sequence

1. Finish socket transport and authentication parity, including Keychain.
2. Finish CodeRouter native, delegated, and team commands.
3. Port app/settings and topology families with source-derived fixtures.
4. Port terminal, notifications, browser, agent, cloud, remote, and
   compatibility families.
5. Add dual-run conformance tests and close every manifest item.
6. Run full release packaging and installed end-user tests.
7. Remove Swift, rebuild, measure, and update this document with the final
   artifact sizes.

## Decision record

### Keep the CLI as a small Rust crate

The existing `cmux-tui` Rust binary has terminal, PTY, browser, remote, and
interactive TUI dependencies. Linking it into the macOS CLI would make the
small control client inherit that graph and increase startup and bundle size.
The CLI and TUI may share small protocol crates, but the CLI must remain a
separate binary until measurements prove otherwise.

### Keep Swift as the oracle during migration

The Swift implementation is still the only complete behavior reference. It
must remain in the app until the source inventory, dual-run tests, and release
checks all pass. Calling the current slice “parity” would be a lazy and unsafe
shortcut.

## Update protocol

After each meaningful step, update **Current state**, **Verification record**,
the affected family row, and this work sequence. Include the command, result,
and any new limitation. Do not mark a family `complete` without conformance
evidence. When the final gate passes, record the commit, build identifier,
universal artifact sizes, installed smoke-test result, and the date Swift was
removed.
