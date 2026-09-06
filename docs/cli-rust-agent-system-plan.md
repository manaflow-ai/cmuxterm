# Agent-first CLI and CodeRouter system plan

Status: migration in progress. The Rust compatibility crate is
`cmux-tui/crates/cmux-cli`. It builds two entry points from one codebase:
`cmux` and `coderouter`.

During the migration installer these are copied as `cmux-rust` and
`coderouter-rust`. This is deliberate. It gives release and end-to-end tests a
real artifact without replacing the production Swift CLI before the parity
gate passes. The macOS app target builds and signs these candidate artifacts;
release stripping includes both binaries in the size measurement.

This plan defines the system contract for moving the macOS CLI from Swift to
Rust. It is written around end-user behavior and agent control. A literal
source-line translation is not a useful correctness test because Swift and
Rust have different runtimes, libraries, and process models. The exact target
is observable parity: argv parsing, output, exit status, socket bytes, files,
environment, authentication, side effects, and error shape.

## System outcome

An agent should need one discoverable control surface:

```text
cmux capabilities --json
  -> capability ids, schemas, permissions, context, lifecycle, errors
cmux capability.invoke <id> --json <input>
  -> one structured result, operation id, and verification hints
```

The human aliases remain short:

```text
cmux cr add codex
coderouter add codex
cmux coderouter claude list --json
```

`cmux` and `coderouter` use the same Rust protocol library. The separate
`coderouter` executable is a supported release artifact. The CodeRouter
engine remains a separately verified upstream executable until its source is
available as a stable embeddable Rust crate. The wrapper and the native cmux
capabilities do not create a second login or a second persistent credential
store.

## Core primitives

### Capability

The primitive is a typed capability, not a screen or a subcommand. Every
capability has:

- a stable id, for example `coderouter.account.add`;
- input schema, including allowed context sources;
- output schema and human rendering;
- lifecycle (`instant`, `stream`, `detached`, or `event`);
- permission requirements (`socket.control`, `account.write`, `network`);
- idempotency behavior and a retry rule;
- verification commands or event predicates.

The CLI, socket, UI command palette, hooks, and agents all invoke the same
capability. The old command names are aliases that compile into capability
requests.

### Context

Context is explicit and inspectable. It may contain the caller workspace,
surface, socket, git repository, branch, selected text, agent session, team,
and authentication state. Context is never inferred from the focused window
when a caller supplied an id or socket.

An agent can request a context snapshot before mutation:

```text
cmux context --json
```

### Operation

Every mutation returns an operation id, status, and a verification hint. The
server may later emit `operation.completed` or `operation.failed` with the same
id. A retry uses the same idempotency key and does not duplicate an account,
workspace, or remote process.

### Event

Events are small semantic facts. The first set is:

```text
agent.session.started
agent.turn.started
agent.turn.completed
agent.approval.requested
agent.question.requested
agent.plan_review.requested
agent.error.reported
agent.state.changed
operation.completed
operation.failed
workspace.created
coderouter.account.changed
```

`agent.blocked` is derived from unresolved approval, question, or plan-review
events. It is not the source of truth.

## Authentication and CodeRouter

There is one cmux session authority. `cmux cr add codex` sends only the
provider and optional label through the local socket as
`aiAccounts.upload`. The app reads `~/.codex/auth.json`, refreshes its existing
session, and uploads the credential. The CLI does not print, persist, or place
OAuth tokens in argv, logs, or a long-lived environment variable.

The advanced CodeRouter CLI receives a short-lived broker configuration from
the cmux app. The configuration is removed after the child exits. The broker
contains the same Stack token pair and team selection already held by cmux.
`coderouter logout` therefore reports that the cmux session owns sign-out.

The broker is a process boundary, not an authentication boundary. The local
socket remains same-user trusted and keeps its password/keychain policy. The
Rust client must match the Swift resolution order: explicit password, then
`CMUX_SOCKET_PASSWORD`, then the shared password file/keychain where the
platform integration supports it.

## Rust module boundary

```text
cmux-cli-core
  argv and capability parser
  legacy v2 socket framing and typed errors
  context and output contracts
  CodeRouter adapter and child-process launcher

cmux (bin)
  top-level cmux aliases and compatibility routing

coderouter (bin)
  standalone CodeRouter entry point using the same adapter

cmux app
  auth coordinator, credential files, backend clients, socket worker

cmux-tui / cmux-remote
  remote terminal and machine protocol; never becomes a dependency of the
  local CLI merely because both projects are Rust
```

The local CLI must stay independent of the full TUI dependency graph. Linking
the TUI crate into the CLI would make a small control client inherit terminal,
PTY, browser, and remote transport code. Shared protocol types may move to a
small crate, but UI and daemon dependencies do not.

## Migration and conformance

1. **Inventory.** Generate a command manifest from Swift dispatch, help text,
   socket method, side effects, and tests. Mark every command as `native`,
   `delegated`, `local-file`, or `pending`.
2. **Transport.** Match v2 request shape, newline framing, auth handshake,
   response timeouts, multiline responses, structured errors, and socket
   selection. Test with a deterministic Unix-socket fixture.
3. **Low-risk commands.** Port version, help, ping, capabilities, rpc, and
   CodeRouter account commands. Compare Swift and Rust stdout, stderr, exit
   code, request method, and params.
4. **Command families.** Port one family at a time. Each family needs a
   behavior fixture and a live socket integration test before routing to Rust.
5. **Dual-run audit.** A test-only mode runs Swift and Rust against the same
   fixture and reports a normalized diff. Secrets are redacted before diffing.
6. **Cutover.** Bundle the Rust universal binary as `cmux-rust`, route the
   installed `cmux` shim to it for complete families, and retain Swift only
   for families whose manifest is still `pending`.
7. **Removal.** Delete Swift CLI sources only after the manifest has no
   `pending` rows and release, hook, remote, and app-launch tests pass.

The current Rust slice proves the transport fixture, native `cr add codex`
request, default socket path, and two binary targets. It is not full parity.
The Swift binary remains the production CLI until the manifest and conformance
suite prove complete coverage.

## Agent ergonomics

- `capabilities --json` is the discovery root. It returns schemas and
  permission requirements, not prose-only help.
- `--json` returns one object with `ok`, `operation_id`, `result`, or
  `error:{code,message,details,retryable,action}`.
- Errors use stable codes. Human text may be localized; codes are not.
- Mutations accept `--dry-run` where a preview is safe.
- Mutations accept `--idempotency-key` and expose the key in the result.
- `--explain` returns the resolved socket, context, capability, and permission
  decision before execution. Secrets are always redacted.
- `--verify` runs the capability's verification predicate and returns the
  observed state.
- Agents can subscribe to event streams with a cursor and resume after a
  disconnect. Event payloads contain references and bounded summaries, not
  terminal transcripts or credentials.
- Every command has a no-socket help path. Agents can discover syntax while
  cmux is closed.
- Workspace, pane, surface, and machine handles accept stable ids and human
  refs. The resolved id is returned in JSON.

## Extension points

Third-party integrations add data, not hardcoded branches. An adapter declares
its id, binary detection, hook merge strategy, semantic event mapping, resume
command, transcript source, capabilities, and permissions. A capability
provider can then add a new agent, review system, or runbook without changing
the CLI parser.

The registry must validate adapter manifests before install. A manifest cannot
request arbitrary filesystem, network, or process access without an explicit
permission and trust decision. The initial registry is local and signed; a
marketplace can be added only after the capability contract and verification
model are stable.

## Size and release policy

The current installed universal Swift CLI is about 46.2 MiB. The bundled
CodeRouter executable is about 15.0 MiB universal. A Rust replacement is a
size improvement only if its complete universal artifact, plus the separate
CodeRouter artifact and required metadata, is below the Swift baseline. The
arm64 and x86_64 sizes must be reported separately because static Rust
dependencies can change the split.

The first small Rust slice measured 1,306,800 bytes (1.25 MiB) universal for
`cmux` and 1,306,864 bytes for `coderouter`, before signing. This is a useful
signal that a dependency-light Rust CLI can save bundle space, but it is not a
full parity measurement. The full command migration must be measured again
after each family is added.

Release CI must record:

- compressed download size;
- installed app size;
- each Mach-O slice size;
- stripped and signed size;
- CodeRouter size and checksum;
- parity manifest coverage;
- output/exit/protocol conformance result.

Rust build scripts keep the repository disk guard active. A local developer
may set `CMUX_ALLOW_LOW_SPACE_BUILD=1` for an explicit test build when the
guard permits it; the installer never sets that override silently.

A lazy download is allowed for advanced CodeRouter features only when the
primary `cr add codex` path works from a fresh cmux download. The release must
fail closed on an unverified CodeRouter checksum.

## Expert trade-offs

| Decision | Why it is coherent | Why an expert could reject it |
| --- | --- | --- |
| Keep Swift as the oracle during migration | It protects behavior while Rust grows | A long dual-stack period increases maintenance; the manifest and cutover gate limit this period |
| Keep CodeRouter as a separate verified executable | Source is not available as a stable crate and release updates stay independent | A second executable adds bytes and a process boundary; a future embeddable crate should replace it only after API, license, and size proof |
| Native `cr add codex` through the cmux socket | It removes a second login and keeps OAuth tokens inside the app auth path | It couples the alias to the app socket; the standalone `coderouter` path remains available for users without cmux |
| Separate small Rust CLI crate instead of linking cmux-tui | It preserves bundle-size control and startup speed | It duplicates some protocol types; move only small stable wire types into a shared crate after measuring dependency growth |
| Capability registry before marketplace | Agents need stable verbs and schemas before listings can compose | It delays marketplace work; adding listings before contracts would compound ambiguity and unsafe permissions |
| Structured errors and verification predicates | Agents can recover and prove state without parsing prose | It requires protocol and server changes; Swift compatibility stays until those fields are implemented |

## Completion gate

The migration is complete only when every Swift command has a manifest row with
passing parity evidence, the Rust universal binary replaces the shipped Swift
resource, `cmux cr add codex` works on a fresh install with one cmux login,
standalone `coderouter` is published and verified, and release size is measured
against the recorded Swift baseline. Until then the goal remains active.
