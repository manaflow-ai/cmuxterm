# PR 9131 — exact e8fda62191 verification

Source: `e8fda62191846e843ea82306d9ac363d29f85bc0`, including main `c05e1b49395aeafe21513de9cc77c64eee190b0a`.

Cloud build: `issue-9127-vault-history-4428611c3a75`, behind the shared build queue, optional backend disabled. The local source guard checked this exact branch/HEAD and no tracked source edits (unrelated Bonsplit worktree state excluded). Build completed successfully and released its lock.

Archive SHA-256, verified on both sides of transfer: `5de6785474993e01ad746560538121929247a0d028e6cf8c6646e09657f8a0b5`.

The real tagged app was operated through CUA on leased `cmux-austin-mini-1`, macOS 26.4. Its runtime identify output confirmed the e8fda62191 install and tag-specific bundle ID/socket.

## Visual evidence

- `sessions-cua-e8.png`: existing Sessions style before switching to History. This is a style reference, not an invented pre-fix screenshot.
- `history-relaunch-cua-e8.png`: History after a real normal quit/relaunch, with both sidebar and standalone pane visible. The captures were personally inspected: compact rows, consistent chrome, long title/detail truncation, and preserved trailing timestamps.

## Live behavior

- Both Sessions/History tabs work in the sidebar and independent pane.
- All five groupings work in each mount: Workspace, Window, Agent, Type, Date.
- Pop-out creates an independent Vault pane; closing the sidebar leaves that pane functional. Reopening the sidebar uses the real View-menu action.
- Initial launch and UI navigation preserve the previous 12 fixture events byte-for-byte: `a796c687f106e1647246bfbc69900aae5b3b03ae9f24c45135e41115128e1e03`.
- Fresh workspace `B83C233E-B79A-48BA-BCF4-94604CB8AA1A` produces exactly create, long-title rename, close.
- Fresh window `2B288B60-8129-4BCE-AAC8-1D7B79AF2B98` produces exactly its workspace create, window open, window close, workspace close. This also exercises the merged initializer dependencies in a real new window.
- All **19** records survive normal quit/relaunch byte-for-byte without synthetic startup/shutdown events: `5bd0a55850b9bea14c58bb89a6e3a5c3e9433e81ac89e49d5d79ec3cdf527502`. Both mounts restore and display the retained events.

## Executed tests on the same source

- Hosted `34326577143`: **36 tests**, in six separately checked batches — 25 History-owner, one launch-transaction, one row layout, two session projection, three OpenCode, four managed-device Cloud policy tests.
- Hosted `34326580660`: the complete Vault tabs/grouping/pop-out UI test passes, **one test / zero failures** (40.486 seconds).
- Remote `CmuxVaultHistory`: **19 tests in three suites** pass.
- Remote `MobileTerminalLaneCoordinatorTests`: **eight tests** pass, including absent-output-provider and failing-output-provider cases. These are package checks, not a phone install.
- Workflow syntax, strict determinism (zero active findings), 840-file test wiring, and the 30 History/Pane localization keys across all 20 locales pass audit.

Full CI `34326370888` has genuine broader app-host failures and is not counted as green. A clean-main focused comparison is being run; matching source alone is not runtime baseline proof. This evidence does not confer merge approval, and the iOS/mobile diff requires Austin to merge. Real VM provisioning, locked-Keychain, and physical-iPhone flows remain unverified.

Finished remote package-build scratch directories were removed after logs were retained. The task's tagged applications and remaining transient build/socket files are cleaned up separately; durable evidence remains available here.
