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
| socket-transport | partial | keychain fallback, all marker variants, and exact timeout/error framing parity |
| coderouter-native | partial | all account verbs and Swift output/error parity |
| coderouter-delegated | partial | complete delegation and broker lifecycle parity |
| coderouter-team | pending | status, machines, Claude team operations |
| app-and-settings | partial | auth status/login/logout is ported; docs, settings, config, themes, welcome, open, and feedback remain |
| topology | partial | window inspection, basic window actions, workspace and pane/surface inspection output are ported; handle normalization, tree, tab, and exact mutation output remain |
| terminal-and-notifications | partial | terminal reads, selection, sends, panel aliases, sidebar status/progress/log forwarding, and basic notification actions are ported; capture, feed, advanced targeting, and exact metadata output remain |
| browser | partial | open, navigate, back, forward, reload, URL, webview focus, snapshot, eval, wait, click/fill/type/press, and profile lifecycle aliases are ported; storage, selector normalization, and exact automation output remain |
| agents-and-hooks | pending | hooks, teams, extensions, restore and feed paths |
| cloud-and-remotes | pending | VM, cloud, remote, SSH, and remote terminal paths |
| compatibility | pending | tmux compatibility and hidden agent commands |

The Rust candidate currently provides the migration slice for capabilities,
context, RPC, ping, identify, window inspection and basic window actions,
workspace and pane inspection and creation, workspace close/select/rename,
surface creation, terminal text reads and sends, basic notification actions,
common browser navigation, automation, and profile aliases, auth status/sign-in/sign-out,
socket refresh/debug controls, limited AI accounts, `cr add codex`, and
CodeRouter delegation. The new topology and browser commands still need
Swift-compatible handle normalization, help text, output formatting, and
side-effect conformance.
The latest stripped Rust candidate binaries are 1,582,704 bytes (`cmux`) and
1,582,712 bytes (`coderouter`) as universal arm64+x86_64 Mach-O files. The
pair is 3,165,416 bytes, about 3.02 MiB. Keeping Swift in production while
the gate is red adds this temporary Rust payload. Removing Swift before the
gate passes would risk breaking commands, so the size increase remains
accepted until cutover.

Known verification gap: Rust auth resolution now supports an explicit password,
`CMUX_SOCKET_PASSWORD`, the shared password file, and the scoped legacy macOS
Keychain entries. The `CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC` override and the
Swift-compatible 305 second login timeout are now implemented. The macOS
Security framework path still needs a macOS build and a live Keychain
conformance test.

Known verification gap: the full Xcode release build and installed end-user
test have not run in this environment. The local build guard requires more
free disk than is available, and no usable xcodebuild MCP tool was exposed.

## Verification record

The following checks passed for the current slice:

- Rust format check.
- Clippy with warnings denied.
- `cargo test -p cmux-cli` (20 tests).
- V1 socket tests for `ping`, window inspection parsing, and window command
  dispatch.
- Identifier rendering tests for `refs`, `uuids`, and `both` modes.
- Password source precedence tests, including the final Keychain fallback.
- V2 request construction tests for workspace, pane, and terminal context.
- Notification list parsing and notification command parsing tests.
- Browser navigation alias parsing tests.
- Browser namespace parsing coverage for the supported automation verbs.
- Browser snapshot socket conformance test (method and surface context).
- Browser profile lifecycle request routing.
- Terminal selection and panel send alias parsing.
- Sidebar metadata v1 forwarding test with workspace context and shell quoting.
- Workspace and surface creation command parsing and boolean flag tests.
- Socket refresh, reload, focus, and surface diagnostic command parsing tests.
- Authentication command parsing tests.
- Universal arm64 and x86_64 Rust builds.
- Stripped universal size measurement: `cmux` 1,582,704 bytes and
  `coderouter` 1,582,712 bytes; 3,165,416 bytes combined.
- CodeRouter broker, marker discovery, installer, and release-strip smoke
  tests.
- `cmux cr add codex` sends `aiAccounts.upload` with no credential in argv or
  socket parameters.
- `python3 scripts/generate-cli-rust-command-inventory.py --check` (pass).
- `git diff --check` (pass).

The authoritative gate command is:

```sh
python3 scripts/check-cli-rust-parity.py
```

It must exit `0` before production cutover. The 2026-09-06 run exits `3`:
the manifest is valid, but all 12 families remain incomplete.

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
