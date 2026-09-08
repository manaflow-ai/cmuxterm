# PR #9131 — exact-HEAD visual evidence

Feature commit: `8f23af29f9c345c4d8fd98bf8a7327571043e697`.

This branch contains only verification artifacts, not application changes, and is not intended to be merged. The screenshots were captured from the tagged app on the leased `cmux-austin-mini-0` fleet Mac on September 8, 2026 UTC. The cloud build was `issue-9127-vault-history-916fdd562a33`.

- `sessions.png`: existing Sessions controls remain compact.
- `history-empty.png`: History before any recorded lifecycle action.
- `history-live.png`: exactly three rows after creating, renaming, and closing one workspace through the tag-bound CLI.
- `history-relaunch.png`: the same three rows after normal quit/relaunch, with no restore/shutdown noise.

All four are actual app-window captures from the tag-bound `debug.window.screenshot` command, not computer-use screenshots. Long titles truncate on one line while timestamps remain aligned. The live and post-relaunch JSONL files were byte-identical; SHA-256: `84e49c5a5b59a5e6ff9d0505b0d3f5a9ef3392292dbca3a4d61690231a27212f`. Both contained exactly the expected three event kinds for the same workspace UUID.

## Limits

The remote Cua provider returned a degraded accessibility tree, failed screenshot capture with `Unknown tool: screenshot`, and produced no observable click/typing input. The Sky provider did not become ready. History was selected through the isolated tag preference followed by normal relaunch; mouse tab switching, grouping-menu interaction, and pop-out behavior remain unverified. No TCC or system settings were changed.

The prescribed cloud build's optional backend DNS failed; the successful retry used `CMUX_DEV_BACKEND_MODE=off`. This verifies the local History UI and persistence, not backend integration.

CI still has an integrity blocker: an app-host job reported success despite actual XCTest and Swift Testing failures. These screenshots are not a claim that CI is genuinely green or that the PR is ready to merge.

Artifacts are hosted separately because the shared native browser was concurrently in use. Publishing them does not change the tested feature HEAD. The temporary local/remote tagged apps and build data were removed after verification; the original cloud archive and full local evidence remain retained.
