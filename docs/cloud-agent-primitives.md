# The cloud primitives an agent needs

Status: roadmap. Companion to docs/cloud-project-environments.md (`vm dev`) and
docs/vm-identity-edge-auth.md (machine identity). Maps the product goals to
primitives, marking what already exists on this branch vs. what's next.

The CLI's job: let a **local agent** (Claude Code, Codex, anything with a shell)
manage cloud workspaces as directly as it manages local files — and let the work
keep running when the laptop closes.

## Goal 1 — port work into the cloud

| Primitive | State |
| --- | --- |
| `vm route` / sticky per-directory binding | shipped |
| `vm push` / `vm pull` (chunked, hashed, excludes) | shipped |
| `vm run --sync -- <cmd>` | shipped |
| `vm exec`, `vm terminal send/read/wait` (drive anything headlessly) | shipped |
| `vm dev` (detect/record/replay environment, named workspace) | designed (cloud-project-environments.md) |
| `vm push --watch` (fs-event incremental sync) | next |
| `vm repo clone <url>` (clone *in* the cloud — big repos never transit the Mac; gh auth via edge-injected credentials, never a token in the guest) | next |

## Goal 2 — agents that outlive the laptop

Detached cmux-tui terminals already survive disconnects: `vm agent` starts a
coding agent in the machine's session and it keeps running with the Mac closed.
What completes the story:

- **Notify without a Mac attached** — the notification relay (this branch)
  bubbles in-VM `cmux notify` into the daemon's durable ledger; the Mac drains
  it on reconnect. Next: the control plane forwards ledger events to push
  (iOS/APNs) so "agent finished" reaches a closed laptop.
- **`vm agent --until-done`** — a supervisor terminal that watches the agent's
  exit receipt (`--on-exit keep` receipts are durable) and runs a follow-up
  (notify, push a branch, open a PR) with no Mac in the loop.
- **Scale-out** — `vm run`/`vm agent` already provision pool machines per task;
  `vm fork` clones a warm environment for parallel experiments. Next:
  `vm agent --fan-out N -- <prompt>` = fork × N + one agent each + a summary
  workspace collecting the results.

## Goal 3 — layouts as data (shipped)

One declarative document on both sides — the `CmuxLayoutNode` schema the Mac
already uses for `cmux new-workspace --layout`, `cmux layout save|get|open` and
cmux.json workspaces (`{"pane":{"surfaces":[…]}}` leaves, `{"direction","split",
"children"}` splits). The daemon's own `LayoutDocument` (pane/tab ids, split ids)
stays the wire truth; the declarative form is what people and agents write.

```bash
cmux vm layout export <machine> [<ws>] [--raw]        # {"name","cwd","layout"}; --raw: the LayoutDocument
cmux vm layout apply  <machine> <file|-> [--name <n>|--workspace <empty-ws>] [--cwd <dir>] [--from-saved <mac-layout>] [--open]
```

- **One implementation, three entrypoints.** `layout export|apply` live in the
  in-VM `cmux` shim (POSIX sh + jq over the daemon's v2 verbs: `workspace run`,
  `pane split --ratio --cwd`, `pane run`, `tab create browser`, `terminal write|keys`).
  The Mac CLI runs that implementation over the exec channel; inside a machine
  the same verb works locally and toward linked peers (`cmux vm layout … <peer>`).
  Presets are just files (a layout saved on the Mac applies with `--from-saved`).
- **Author without opening**: `apply` builds a new (or an empty) workspace
  headlessly; `command`s are typed into login shells so panes survive them and
  the scrollback shows what ran. `--open` is the only thing that touches the Mac.
- **Monitor without opening**: `vm tree --json` carries the topology; `export`
  adds the geometry; `terminal read|wait` the content.
- **Click-to-materialize (shipped)**: `vm workspace open`, `--open`, and the
  sidebar row build the local panes from the screen's LayoutDocument — split
  directions, divider ratios, tabs per pane — falling back to one pane per
  terminal only when no layout is known. Geometry travels machine→Mac as data;
  nothing in a document can name a Mac surface or socket (the same boundary
  the notification relay enforces).
- **Next**: `vm layout apply` into a non-empty workspace as an additional
  screen; a `--watch` that re-exports on daemon layout events.

## Goal 4 — everything an agent needs to set up a working environment

The checklist an agent runs through, each item a primitive (not a doc):

1. **Machine**: `vm route`/`vm new --size` (per-size snapshots) — shipped.
2. **Code**: `vm push` (shipped) / `vm repo clone` (next).
3. **Toolchain + deps**: `vm dev` detect→record→replay; devcontainer.json
   honored — designed.
4. **Secrets**: `vm env set|ls|rm` — shipped machine-local (0600 file on the
   persistent volume, sourced by every shell cmux starts: terminals, `vm exec`,
   `vm agent`, layout panes, in-VM `cmux agent`). Values never ride `vm.exec`:
   they cross the machine's end-to-end link into `cmux env receive` with PTY
   echo off (`CloudEnvDelivery`), so no server, command line, or screen ever
   holds them; per-(user, project) storage and edge-resident values remain the
   long game (docs/vm-identity-edge-auth.md).
5. **Services**: recipe `services` (postgres/redis via the baked docker) with
   health gates — next, part of `vm dev` P2.
6. **Workspace + layout**: `vm workspace new --name` + `vm layout apply` —
   shipped; the person's click reproduces the geometry.
7. **Verification**: recipe `checks` in a durable terminal; the exit receipt is
   the proof the environment works — designed.
9. **Identity**: a machine knows who it is — `cmux whoami` / `cmux reflect`
   (exe.dev-style reflection on the edge-asserted route-token identity; shipped) —
   and finds its peers itself (`/peers`, trusted-carrier routes). Scoped mutations
   and git credentials for the machine principal are next (docs/vm-identity-edge-auth.md).
8. **Handoff**: `vm handoff` (shipped), `cmux notify` from inside (this
   branch), peer links for multi-machine pipelines (`vm link`, shipped) — and,
   inside a machine, the Mac's own verbs for its session and its peers
   (`cmux terminal send|read|wait`, `send-key`, `new-workspace`, `layout`,
   `env`, `cmux vm agent <peer> …`): an agent in the cloud has parity with an
   agent on the Mac.

## Sequencing

1. ~~`vm layout export/apply`~~ shipped, with geometry-honoring open and the
   in-VM parity verbs (`cmux terminal|send-key|new-workspace|layout|env`,
   `cmux vm … <peer>`).
2. ~~`vm env set|ls|rm`~~ shipped machine-local; control-plane/edge storage later.
3. `vm dev` P1 (route+sync+detect+named workspace+layout) — unlocks goal 4 in
   one verb; today it is a four-line recipe (route, push, env set, layout apply).
4. `vm push --watch`, `vm repo clone`, recipe `services`.
5. Push-notification forwarding for the ledger; `vm agent --until-done`,
   `--fan-out`.
