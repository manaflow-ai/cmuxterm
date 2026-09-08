# PR #12090 visual verification evidence

Branch head verified: `5302c75` (issue-12044-cloud-sidebar-ports-followup). Tagged Debug build `cmux DEV issue-12044-cloud-sidebar-ports-followup` built on the cloud builder from that head, pointed at the staging control plane (`https://cmux-staging.vercel.app`) with the development-project dogfood account, on 2026-09-07 (local).

Machine: a fresh Base machine (`vm-fec08a3540914755b80c5db2bac679d4`, "followup-dogfood") whose only workspace has one pane holding two tabs.

- `sidebar-cloud-crop.png`: the right sidebar's Cloud panel. The workspace row reads "1 terminal · 1 more tab"; one pane row (the shown tab) carries a "+1" badge; the hidden tab nests beneath it; the Terminals pool still lists both terminals once each.
- `sidebar-cloud-full.png`: the whole window for context.
- `vm-tree.txt`: `cmux vm tree` through the tagged app's socket, rendering the same shape (`(+1 hidden)` on the shown tab, `↳ tab` beneath it).
- `vm-tree-views.txt`: the per-tab coordinates from the catalog payload (`pane_index`, `screen_index`, `focused`).

The two other machines in the capture ("test", "adfdf") are pre-existing staging machines whose daemons do not connect; their rows show the link-error state from #12051 and are not part of this PR.

## Follow-up validation — September 8, 2026 UTC

The screenshots above are historical evidence for `5302c759d4`, not final-head dogfood of the shared Core projection or the subsequent screen/tab fallback fixes.

- [Failing regression at test-only commit 543fc13bdf](layout-regression-red-543fc13.txt): missing screen IDs incorrectly collapse five expected pane rows into two. The new test fails before the fix.
- [Passing Core package tests at 0d6b3e7e9e](core-tests-green-0d6b3e7.txt): 10 layout tests and all 76 package tests pass on a leased Mac, Xcode 26.3, Release. No package tests were excluded. The Core/Foundation sources are unchanged by the later tab-snapshot normalization/test commits.
- Planner benchmark: 1,000 workspaces × 8 panes × 4 tabs = 32,000 placements in 0.004713417 seconds. This measures the pure planner only, not AppKit/SwiftUI refresh latency. No artificial record cap or speculative revision cache is added.
- [Hosted app-parser test failure at 6073048803](hosted-parser-failure-6073048.txt): the test target cannot compile because unchanged CLILocalTmuxReviewRegressionTests references CLI-only types. This is the main-branch blocker tracked in #12055, not a passing parser regression. Run: https://github.com/manaflow-ai/cmux/actions/runs/34193492992 . No test-source exclusions were made in that run or in the PR branch.
- The new rename-delta regression drives the real parser and sidebar builder, checking the shown row, hidden-tab ordering, and subsequent full refresh for both omitted and explicit indices. [Final-head run 34195721806](https://github.com/manaflow-ai/cmux/actions/runs/34195721806) failed to compile unchanged `SurfaceCatalogTests` references to missing APIs, also tracked in #12055. [Failure diagnostics](hosted-rename-failure-1e092fc.txt). The focused test did not execute; no baseline files were excluded.
- Final tagged dogfood remains unverified: the protected shared build queue stayed occupied for over 56 minutes, and the canonical agent credential pair is incomplete. Only this task's queued launch was canceled to prevent an unattended later app launch; no other worker or shared lock was changed. No tagged app, socket, DerivedData, or package-test lease remains from this closeout.

The [single PR audit](https://github.com/manaflow-ai/cmux/pull/12090#issuecomment-5579188766) is authoritative for the final HEAD, build status, review dispositions, and remaining verification gaps. Authenticated Cloud interaction and fresh before/after evidence are not claimed while the agent credential pair is incomplete.
