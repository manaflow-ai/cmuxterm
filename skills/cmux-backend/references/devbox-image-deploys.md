# Shipping a devbox image

Two things ship on different clocks, and only one of them ships by merging.

**Code ships on merge.** `web/services/vms/images/manifest.json` is the source of
truth for the image a machine boots. `resolver.ts` reads the `defaultForKind`
entry for the requested kind and size; no environment variable selects an image
(the `envVar` field is legacy). Merging a manifest bump to main deploys it with
the next Vercel deploy.

**Image content ships on a bake.** Everything under
`web/services/vms/images/devbox/` plus `scripts/build-devbox-freestyle.ts` is
input to a Freestyle snapshot. Editing those files and merging changes nothing
on any machine: the manifest still points at the snapshot baked before the edit.

## Baking and promoting

From `web/`, with the deployment account's `FREESTYLE_API_KEY`:

```bash
bun run devbox:promote freestyle --no-desktop   # base ladder
bun run devbox:promote freestyle                # desktop ladder
```

`promote-devbox-image.ts` runs a stale-checkout preflight (HEAD must equal
`origin/main`, or `CMUX_BAKE_ALLOW_BRANCH=1`), bakes, verifies by booting a real
VM, derives the size ladder, and writes the manifest entries. A failed verify
writes nothing. The output is a manifest diff: open it as a PR, and merging that
PR is the promotion. Twelve entries move at once (base and desktop, six sizes).

## Drift

`bun run devbox:drift:check` compares each default entry's `repoCommit` against
the image inputs in the working tree and names the files that changed since the
bake. The `Cloud VM image contract` workflow runs it on every PR and push that
touches image files. It is a report, not a gate: source and image are allowed to
move apart (a bake needs a provider credential and real VMs), but never
silently. When it fires, either bake and promote, or accept that the change is
queued for the next bake.

A bake is not reproducible: agent CLIs, apt, and the ble.sh nightly all resolve
at bake time, so every promotion carries unrelated upgrades. The manifest entry
records `agentToolResolvedVersions`, and the promotion PR diff is where those
upgrades get reviewed.
