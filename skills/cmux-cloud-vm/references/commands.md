# cmux vm command reference

`cloud` is an alias for `vm` (`cmux cloud ls` == `cmux vm ls`). The global `--json` flag works on every subcommand and may appear before or after the subcommand. All of this requires the cmux app running and a signed-in account.

## Discovery: the cloud tree

```bash
cmux auth status                       # host: signed in; guest: daemon/edge route health
cmux vm ls                             # NAME / LABEL / STATE / PROVIDER / IMAGE + plan meter (+ free-window countdown)
cmux vm ls --json                      # {vms: [{id, status, image, createdAt, freeAccessExpiresAt, capabilities: {ports, …}}], limits: {maxActiveVms, planId, freeAccessWindowDays, freeAccessExpiresAt}}
cmux vpn status                        # this build's WireGuard tunnel to its private machine network (machines open no public port): up, down, or up for another enrollment (stale)
cmux vpn up                            # enroll this Mac and bring the tunnel up (sudo); a stale tunnel (rotated keys) is replaced. One tunnel per deployment (`cmux` for production, `cmux-staging`/`cmux-dev` for dev builds), so a dev build and the production app can both be up
cmux vpn down                          # take this build's tunnel down (sudo)
cmux vm tree                           # the surface catalog: This Mac (terminals by workspace, browsers), then every machine → Workspaces, Ports, VNC Displays, Terminals
cmux vm tree <id> --refresh            # one machine (`local` for This Mac), re-synced first (fleet + provider refresh)
cmux vm workspace new <id> [--name n]  # a new cmux-tui workspace on the machine (⌘N there), opened as a new local workspace
cmux vm workspace open <id> <ws-id>    # open a machine workspace as a NEW local workspace: one pane per terminal/browser (clicking its row)
cmux vm workspace open <id> <ws-id> --here [--workspace <local>]      # into the current local workspace: one pane + the rest as tabs (drop a workspace row onto a pane)
cmux vm workspace open <id> <ws-id> --tabs [--pane <p>]                # all as tabs of the focused/--pane pane (CLI placement)
cmux vm workspace open <id> <ws-id> --pane <p> --left|--right|--up|--down   # what dropping the row on that pane edge does
cmux vm workspace rename <id> <ws-id> <name>   # rename that workspace (the row's "Rename…")
cmux vm workspace close <id> <ws-id>   # CLI-only: close that workspace but keep its terminals running in the Terminals pool
cmux vm workspace rm <id> <ws-id>      # close that workspace AND kill every terminal in it (the row's "Close Workspace…" / hover ×). Permanent.
cmux vm terminal close <id> <term-id>  # end one terminal on the machine (the sidebar's ×); its local panes close too
cmux vm terminal send <id> <term-id> [text] [--keys enter,ctrl+c,…]   # type into the terminal headlessly (as-is, no newline), then press named keys (chords join with +); no pane, no focus
cmux vm terminal read <id> <term-id>   # the visible screen as text (--json: + rows, cols, cursor)
cmux vm terminal wait <id> <term-id> --pattern <regex> [--timeout <s>]   # block until the screen matches (default 30 s); exit 1 on timeout
cmux vm tree --json                    # {machines: [{id, local, name, status, link_state, …}], resources: [{id, machine, kind, key, title, detail, lifecycle, agent, remote_workspace, port, url, open, open_surface_ids}], projections: […]}
cmux surface ls [--json]               # same catalog; `surface open <resource>` / `surface new-terminal --machine <m>` are the generic verbs
cmux vm status <id>                    # provider, status, image
cmux vm stats <id>                     # CPU/mem/disk now; sleeping machines stay asleep
cmux vm tools <id>                     # which tools are installed
cmux vm ports <id>                     # listening TCP ports inside the machine
cmux vm handoff <id>                   # short attach block to paste to a human or another agent

# Guest-safe auth and CodeRouter commands (run inside a Cloud VM)
cmux auth status [--json]              # daemon, TLS edge, and VM-bound route status
cmux coderouter status [--json]        # same route/auth report
cmux coderouter usage                  # this machine's 30-day usage JSON
cmux coderouter models                 # models exposed through the edge
cmux coderouter agent <agent> ...      # run claude/codex/opencode/pi via CodeRouter
cmux agent <agent> ...                 # short alias for coderouter agent

# In-VM parity verbs (the Mac spellings, against this machine's own session; default target = $CMUX_TUI_TERMINAL_ID)
cmux tree [--json]                     # session snapshot (workspaces, screens, panes, tabs, terminals)
cmux new-workspace [--name <n>]        # workspace create
cmux new-split <left|right|up|down> [--pane <pane_id>]
cmux send [--terminal <id>] <text…> ; cmux send-key [--terminal <id>] <key…> ; cmux read-screen [--terminal <id>]
cmux terminal send <id> [text] [--keys k1,k2] | read <id> | wait <id> --pattern <re> [--timeout <s>] | close <id>
cmux layout export [--workspace <ws>] [--raw] | cmux layout apply [--workspace <ws>|--name <n>] [--cwd <dir>] [<file>|-]
cmux env set KEY=VALUE… [--from-file <.env>] [-] | ls [--show] [--json] | rm KEY… | path
cmux vm <verb> <peer> …                # any of the above on a linked peer machine (see "Machine-to-machine links")
```

Tree line shapes:

```
vivid-newt  running  · 24 GB · 16 GB disk · link connected
  workspaces/                                  ← one machine, many workspaces: what you open and drag
    main  ws_3c1…  *  (cmux vm open vivid-newt/ws_3c1…)
      ● term_2f9…  bun test  ~/work/app  [agent claude running]  (open: surface:4)
      ○ term_88a…  bash                                  ← exited
    tests  ws_9ab…  (cmux vm open vivid-newt/ws_9ab…)   ← a second workspace on the same machine
  ports/
    3000  http  (cmux vm open vivid-newt:port/3000)
  VNC Displays/
    ● display:1  Desktop  noVNC  (cmux surface open vivid-newt/display/display:1)
  terminals/                                  ← every terminal resource the machine owns
    ● term_2f9…  bun test  ~/work/app             ← shown in a workspace
    (detached — no tab on the machine shows these)
      ● term_c04…  sleep 1000                   ← live, but in no workspace's layout
```

The sidebar shows the same tree in the same order: the machine's **Workspaces** group first (always its own row, with a ＋ that is `vm workspace new`; each workspace lists exactly its layout — a terminal whose tab closed is gone from the folder), then **Ports**, **VNC Displays** (one row per screen), and last, its own section, **Terminals** (every terminal resource the machine owns, detached ones greyed; always present, ＋ = `surface new-terminal`). Every sidebar verb has a CLI verb — see [sidebar-parity.md](sidebar-parity.md). `<machine>/<workspace>` addresses take the `ws_…` id, or the workspace name only when exactly one workspace has it (colliding names need the id); an empty workspace still resolves, and `vm open` starts a shell in it.

## Surfaces: one open path for terminals, screens and browsers

```bash
cmux surface open vivid-newt/terminal/term_2f9c…                 # reuse the pane showing it, else open beside you
cmux surface open vivid-newt/terminal/term_2f9c… --new           # a second pane on the same terminal
cmux surface open vivid-newt/display/display:1 --pane pane:3 --left   # the VNC screen, split left of pane 3
cmux surface open local/terminal/<uuid> --workspace workspace:2  # move a local terminal into another workspace
cmux surface new-terminal --machine vivid-newt --remote-workspace ws_3c1… --name "tests" -- bun test
cmux surface new-terminal --machine local --cwd ~/src/app        # a new local shell
```

Resource ids come from `surface ls --json`; `--pane` + a side uses the same drop rules as dragging a row from the sidebar.

## Routing: which machine, without running anything

```bash
cmux vm route                          # machine=<id> created=false / reason: reused, warm machine for this directory
cmux vm route --cwd ~/src/app --json   # {machine, created, reason, would_provision, directory}
cmux vm route --new --provision        # actually create the fresh pool machine the router would use
```

Policy (shared with `run` and `agent`): the machine bound to the directory → an awake idle pool machine → a sleeping pool machine → provision (only with `--provision` here) → at the plan cap, the least-loaded busy pool machine. Hand-made machines are never drafted. New cmux-created machines clear the provider idle timeout; a sleeping entry is an older/provider-managed or explicitly paused machine and is woken before an open operation.

## Lifecycle

```bash
cmux vm new --detach                   # new Desktop machine (screen + shell), headless create
cmux vm new --base --detach            # shell-only machine
cmux vm new --size 16g --detach        # memory preset: 2g|4g|8g|16g|24g|32g or raw MB (disk follows memory, 16 GB max)
cmux vm new --name "build box" --detach # display label; the id stays the address
cmux vm wait <id> [--timeout <sec>] [--wake]   # block until ready; --wake also wakes it
cmux vm rename <id> <label>            # display label; the id stays the address
cmux vm rename <id> --clear
cmux vm rm <id>                        # PERMANENT delete of machine + data (aliases: destroy, delete)
```

Without `--detach`, `vm new`, `vm fork`, and `vm restore` also open the machine as a workspace in the user's app.

## Base (the pinned persistent slot)

```bash
cmux vm base open                      # open (or create) the one persistent Base machine
cmux vm base reset --reason "fresh"    # new Base generation; the old VM is retained
```

## Running work

```bash
# routed (no machine id): sticky per directory, then an idle pool machine, then provision
cmux vm run -- <command...>
cmux vm run --sync -- bun test                 # push cwd to work/<basename>, run there
cmux vm run --sync --pull work/app/dist -- sh -c 'cd work/app && bun run build'
cmux vm run --machine <id> -- <command...>     # pin; --new forces a fresh pool machine
cmux vm run --size 16g --new -- <command...>   # size applies to machines this run creates

# a coding agent as a detached terminal in the machine's cmux-tui session
cmux vm agent --agent claude --sync -- "run the tests and fix failures"        # bare prompt → claude -p …
cmux vm agent --agent codex --machine <id> -- exec "summarize work/app"        # flag/subcommand-led args pass through
cmux vm agent --agent opencode --no-open --json -- "add a README"              # headless; {terminal_id, workspace_id, reattach}
cmux vm agent --agent pi --name "pi: docs" --cwd ~/src/app --sync -- "write docs for src/"
# agents: claude | codex | opencode | pi (preinstalled under /root/.npm-global/bin)

cmux vm exec <id> -- <command...>      # one command; remote exit code passes through; ~30 s default cap
cmux vm exec <id> --json -- ls -la     # {stdout, stderr, exit_code}
cmux vm exec <id> -- sh -c 'nohup bun run build > /tmp/build.log 2>&1 &'   # long work: background, then poll
cmux vm exec <id> -- tail -n 20 /tmp/build.log
```

## Files

```bash
cmux vm push <id> <local-path> [remote-path]        # file or directory (tarball), SHA-256 verified
cmux vm push <id> ./site --exclude dist             # extra excludes on top of defaults
cmux vm push <id> ./repo --no-default-excludes      # include .git, node_modules, ...
cmux vm pull <id> <remote-path> [local-path]        # file or directory back to local disk
```

Aliases: `upload` / `download`. Transfers ride the exec channel (no SSH), chunked base64, 256 MB cap; directories travel as tarballs and merge into the destination. Remote paths are relative to `/root` (the persistent volume).

## Layouts (the shape of a machine workspace)

```bash
cmux vm layout export <id> [<ws-id|name>] [--raw] [--json]   # {"name","cwd","layout": Node}; default: the focused workspace; --raw: the daemon LayoutDocument (pane/tab ids, split ids)
cmux vm layout apply <id> <file>|- [--name <n>] [--cwd <dir>] [--open] [--json]   # build a NEW workspace from the document; --open shows it here with the same geometry
cmux vm layout apply <id> <file> --workspace <ws-id>          # into an existing EMPTY workspace (from `vm workspace new --no-open`); a non-empty one is refused
cmux vm layout apply <id> --from-saved <name> [--open]        # a Mac saved layout (`cmux layout save <name>`), applied in the cloud
```

Document (identical to `cmux new-workspace --layout`, `cmux layout get`, cmux.json workspaces):

```json
{"name": "app", "cwd": "/root/work/app",
 "layout": {"direction": "horizontal", "split": 0.6, "children": [
   {"pane": {"surfaces": [{"type": "terminal", "name": "agent", "command": "claude"}]}},
   {"direction": "vertical", "split": 0.5, "children": [
     {"pane": {"surfaces": [{"type": "terminal", "name": "tests", "command": "bun test --watch"},
                            {"type": "terminal", "name": "logs", "cwd": "logs"}]}},
     {"pane": {"surfaces": [{"type": "browser", "url": "http://localhost:3000"}]}}]}]}}
```

- Wrappers accepted: the bare `layout` node, `{"name","cwd","env","layout"}`, or a saved layout `{"name","description","workspace":{…}}`.
- `horizontal` = side by side (first child left), `vertical` = stacked (first child top); `split` = the first child's share, 0.1–0.9 (default 0.5).
- Surface: `type` terminal|browser (`project` is Mac-only and skipped with a warning), `name` (tab name), `cwd` (relative to the document `cwd`, default `/root`), `env` (process environment of that shell), `command` (typed into the shell, then Enter — the shell survives it), `url` (browser), `focus`.
- Every terminal is a login shell (`bash -l`), so `vm env` values and the agents' PATH apply. Output: `OK workspace=ws_… name=… panes=N surfaces=M` or `--json` `{workspace_id, workspace_name, panes:[{pane_id, surfaces:[{type, terminal_id|browser_id, tab_id, name}]}], warnings}`.
- The same verb exists inside the machine (`cmux layout export|apply`) and toward linked peers (`cmux vm layout … <peer>`); the Mac form runs that implementation over the exec channel. A machine whose shim predates it says so (reconnect: `cmux vm tree <id> --refresh`).
- Exit codes: 0 built; 1 daemon refused (message names the op); 2 invalid document (message names the JSON path, e.g. `$.children[1]`) — nothing is created on a 2.

## Environment (project secrets and settings on a machine)

```bash
cmux vm env set <id> KEY=VALUE [KEY2=VALUE2 …]        # /root/.config/cmux/env (0600) on the persistent volume
cmux vm env set <id> --from-file .env                 # dotenv rules: blank and # lines skipped, optional `export `, matching quotes stripped
cmux vm env set <id> -                                # KEY=VALUE lines on stdin (preferred for scripts: nothing in argv)
cmux vm env ls <id> [--show] [--json]                 # names; --show adds values; --json {path, keys, values?}
cmux vm env rm <id> KEY [KEY2 …]
```

Values are sourced by every login/interactive shell on the machine (a one-line hook in `~/.profile` and `~/.bashrc`, installed on first `set`), so every terminal cmux starts (`vm open`, `surface new-terminal`, `vm agent`, layout panes), `vm exec`, and the in-VM `cmux agent …` see them. Keys must match `[A-Za-z_][A-Za-z0-9_]*`.

Transport: `vm env set` is the one `vm` verb that does **not** ride `vm.exec`. Values go to the app over the local socket and from there over the machine's cmux-tui link (Noise-authenticated end to end, on the private WireGuard network) into the machine's `cmux env receive`: a receiver terminal turns PTY echo off, prints `CMUX-ENV-READY`, reads base64 lines until `CMUX-ENV-END`, writes `~/.config/cmux/env` (0600), and answers `CMUX-ENV-OK keys=<n>`; the sender closes the terminal. So a value is never in a command line, never in the control plane or the provider API, never on a screen or in scrollback (the daemon does not journal input), and `ls` never prints one without `--show`. Inside a machine, `cmux vm env set <peer> …` uses the same handshake toward a linked peer. Snapshots, forks, and templates carry the file (it lives in `/root`): `cmux vm env rm` what must not travel before `vm promote-template`. A machine whose shim predates the verb is reported as such (reconnect: `cmux vm tree <id> --refresh`).

## Opening things for the human (`vm open`)

```bash
cmux vm open <id>                      # the machine's shell (same as `vm shell`); desktop machines also get their screen beside it
cmux vm open <id>/<ws>                 # a cmux-tui workspace (ws_… id or name): its focused terminal, or a new shell if empty
cmux vm open <id>/<ws>/<term_…>        # one terminal — focuses the pane already showing it instead of opening a second
cmux vm open <id>:desktop              # the noVNC screen as a browser pane (also: `cmux vm desktop <id>`)
cmux vm open <id>:port/3000            # private tokened URL for an HTTP port, as a browser pane
cmux vm open <id> 3000                 # same as :port/3000
cmux vm open <id> 3000 --print         # URL only, no pane
cmux vm open … --workspace <ws> --focus true   # target a local workspace; focus the new pane (default: open beside you)
cmux vm shell <id>                     # a plain terminal on the machine (like ssh): one terminal in its cmux-tui session, attached in a pane
cmux vm tui <id>                       # the FULL cmux-tui client in a pane (its own workspaces/panes) — only when you want the client itself
```

`vm open` prints `OK surface=… workspace=… terminal=… [reused=true]`; `--json` prints the socket payload.

## Checkpoints, forks, templates

```bash
cmux vm snapshot <id> [--name <name>]  # checkpoint; prints the snapshot id (alias: checkpoint)
cmux vm fork <id> [--name <n>] [--detach]      # clone for a parallel experiment
cmux vm restore <snapshot-id> [--detach]       # snapshot -> new tracked machine
cmux vm promote-template <id>          # template-named snapshot for reuse
```

## Machine-to-machine links (`vm link`)

```bash
cmux vm link <src> <dst>               # grant <src> a cmux-remote link to <dst>
```

The Mac brokers the destination route and a single-use enrollment invitation,
then writes only that scoped peer grant into `<src>`. From inside the source
machine, the installed `cmux` shim can run `cmux vm exec <dst> -- <command>`,
`cmux vm tree <dst>`, `cmux vm terminal send|read|wait|close <dst> <term> …`,
`cmux vm send-key <dst> <term> <keys…>`, `cmux vm workspace new|rename|close|rm <dst> …`,
`cmux vm agent <dst> --agent <a> [--name <n>] [--cwd <dir>] -- <prompt>` (a durable
terminal on the peer running `cmux agent <a> …` with the peer's own CodeRouter config),
`cmux vm layout export|apply <dst> …`, and `cmux vm env set|ls|rm <dst> …`; no
control-plane credential enters a machine.

## SSH (provider-dependent)

```bash
cmux vm ssh <id>                       # cmux-managed SSH workspace (not on every provider)
cmux vm ssh-info <id>                  # raw SSH endpoint details when available
```

The default cmux Cloud provider attaches through the cmux-tui remote daemon, not SSH — when `ssh` errors, use `exec`, `agent`, or `open` instead.
