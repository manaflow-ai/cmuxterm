# PR #12090 visual verification evidence

Branch head verified: `5302c75` (issue-12044-cloud-sidebar-ports-followup). Tagged Debug build `cmux DEV issue-12044-cloud-sidebar-ports-followup` built on the cloud builder from that head, pointed at the staging control plane (`https://cmux-staging.vercel.app`) with the development-project dogfood account, on 2026-09-07 (local).

Machine: a fresh Base machine (`vm-fec08a3540914755b80c5db2bac679d4`, "followup-dogfood") whose only workspace has one pane holding two tabs.

- `sidebar-cloud-crop.png`: the right sidebar's Cloud panel. The workspace row reads "1 terminal · 1 more tab"; one pane row (the shown tab) carries a "+1" badge; the hidden tab nests beneath it; the Terminals pool still lists both terminals once each.
- `sidebar-cloud-full.png`: the whole window for context.
- `vm-tree.txt`: `cmux vm tree` through the tagged app's socket, rendering the same shape (`(+1 hidden)` on the shown tab, `↳ tab` beneath it).
- `vm-tree-views.txt`: the per-tab coordinates from the catalog payload (`pane_index`, `screen_index`, `focused`).

The two other machines in the capture ("test", "adfdf") are pre-existing staging machines whose daemons do not connect; their rows show the link-error state from #12051 and are not part of this PR.
