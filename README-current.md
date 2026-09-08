# Vault History verification evidence

This evidence-only tree does not modify the feature branch. PR #9131 remains **unmerged and not fully verified**.

## Actual CUA captures — e13a1158a84, macOS 26.4

- `sessions-cua-e13.png`: compact existing Sessions controls before selecting History.
- `group-menu-cua-e13.png`: real History grouping menu opened through CUA.
- `popout-cua-e13.png`: sidebar and independent Vault pane after pop-out.
- `relaunch-cua-e13.png`: independent pane after normal quit/relaunch; the same three intentional workspace-created/renamed/closed records remain.

These are provider screenshots, not the older DEBUG screenshot fallback. The CUA flow exercised tab switching, grouping, pop-out, hiding the sidebar, standalone-pane tabs, and normal quit/relaunch. Lifecycle creation/rename/close actions used the tag-bound CLI. Persistence snapshots matched byte-for-byte (SHA-256 b4198976f36bdb7f30ecf52447b4b26b23a6c3e8a64ecf384721f91d3380e48a). They are **not exact f5b3 HEAD screenshots**. The app ran with optional backend disabled; no real VM was provisioned.

## Actual failed hosted UI capture — cb65258755f, macOS 15

`ui-failure-cb65-contact-sheet.png` shows the final 110 seconds of run 34196051160. History visibly mounts; the title-aware XCTest grouping query then fails and the app hierarchy cannot be retrieved. cb65 and current f5b3 have identical app/UI-test source; f5b3 run 34197382422 reproduces the failure. The stack-sampling diagnostic run is 34198225587 at diagnostic-only c87a1ebd0c659fbc6919fa623f38bdfd0e5d210b. No claim is made yet that this is either a shipping hang or merely a selector defect.

## Exact corrected test/fix pair

- Test-only: fe4ab61c533bb47d70bb7d32318ace4b0f481262.
- Fixed feature HEAD: f5b3d2cf0a91e7900b43fb99f23d17c0315ebbb3.
- `retention-red-fe4a.log`: 18 package tests, six expected failures in default/custom retention cases.
- `retention-green-f5b3.log`: all 18 package tests / 3 suites passed. Both package runs used separate owned remote macOS 26.4 / Swift 6.2.4 paths, exported directly from their commits.
- Closed-window reopen red run 34197375413: 17 tests, exactly one invalid-restore assertion (a phantom windowOpened).
- Closed-window reopen green run 34197378782: all 17 tests passed, including both valid and invalid snapshots. Both hosted macOS 15 logs were inspected.

The superseded reopen fixture in 4b10/cb65 incorrectly expected live identities to reject restore; run 34196047234 is excluded from regression proof. Live identities are intentionally remapped. No assertion was weakened to hide this mistake; the corrected fixture exercises a genuinely unrestorable panel via the real reopen/validate/discard path.

Earlier 8f23 DEBUG captures and their original README remain in this tree for provenance. Final tagged build, final-HEAD CUA/persistence evidence, full CI integrity, and resource cleanup remain pending. Required badge success alone is not merge approval.
