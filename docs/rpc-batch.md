# RPC batch workflows

`cmux rpc-batch workflow.json` executes a sequence of v2 API calls in one CLI
process. This reduces process launches and, for local Unix sockets, connection
and authentication setup when an agent needs several API operations. Relay
transports retain their existing per-request connection behavior.

```json
[
  {"id": "create", "method": "workspace.create"},
  {
    "id": "rename",
    "method": "workspace.rename",
    "params": {
      "workspace_id": {"$ref": "create#/workspace_id"},
      "title": "Batch workspace"
    }
  }
]
```

```bash
cmux rpc-batch workflow.json --dry-run
cmux rpc-batch workflow.json
cat workflow.json | cmux rpc-batch -
```

The dry run validates the full input without discovering or connecting to a
socket. It reports `{"ok":true,"dry_run":true,"requests":2}`. It validates the
plan structure and references, not whether the server supports a method or will
accept its parameters. Normal execution also validates the entire plan before
connecting, so a malformed final request cannot leave an earlier mutation applied.

## Input contract

The input is a nonempty JSON array, at most 1 MiB, with at most 256 requests and
64 JSON container levels. Each request accepts only these keys:

| Key | Value |
| --- | --- |
| `id` | Required unique ASCII identifier: letters, digits, `_`, `-`; 1–128 bytes |
| `method` | Required v2 method: letters, digits, `.`, `_`; 1–128 bytes |
| `params` | Optional object, default `{}` |

`events.stream` and `auth.*` cannot be batched because they have streaming or
authentication semantics. Batch execution uses the existing socket permissions,
authentication, automation attribution, and per-operation timeout. It introduces
no new server endpoint or permissions. It does not add implicit focus commands.
Explicit focus methods retain their usual behavior.

Global `--socket`, `--password`, and `--json` work as usual. Output is always JSON.
`--window` and `--id-format` are rejected; put explicit targets in each request's
parameters. Results preserve all server fields and original identifiers, so
reference resolution does not depend on presentation formatting.

## Result references

A singleton object `{"$ref":"create#/workspace_id"}` replaces that whole value
with the value at `/workspace_id` in the earlier request's **result**, not its
protocol envelope. `create#` refers to the entire result. References work inside
nested objects and arrays and preserve numbers, booleans, objects, arrays, and null.
Strings are never interpolated or passed to a shell.

Paths use JSON Pointer tokens: `~1` means `/`, `~0` means `~`, an empty token means
an empty object key, and array indexes are zero-based decimal integers without
leading zeroes. URI percent decoding is not performed. A literal `$ref` key is
reserved in input parameter objects; it cannot be combined with other keys.
Values returned by the server are substituted once and never interpreted as
new references.

References must point to an earlier request. Cycles, forward references, duplicate
IDs, and malformed pointers fail preflight. A nonexistent result path or reference
to a failed request fails that dependent request before it is sent.

## Failures and results

Execution is sequential, **not atomic**. Completed requests are not rolled back.
By default, the first error stops execution and later requests are reported as
`skipped`. `--continue-on-error` permits independent requests to continue after a
complete server error or an unresolved reference. Transport failures always stop
execution: a missing response may mean the server already applied the operation.
No automatic retries are added by batching.

A report contains `ok`, ordered `results`, and `metrics`. Each result has its `id`,
`method`, `status` (`succeeded`, `failed`, or `skipped`), and `duration_ms`.
Successful results include `result`; failures include `error.code` and, for
classified RPC failures, the transport diagnostic in `error.message`.
Unattempted skipped requests have zero duration.

Metrics include `requests`, `attempted` (actual transport calls), `succeeded`,
`failed`, `skipped`, and total `duration_ms`. Execution timing uses a monotonic
clock and excludes input parsing, connection setup, and authentication. Failed
references count as failed requests but not attempted transport calls.

Exit codes are **0** for complete success, **1** for execution/connection failure,
and **2** for invalid input. Execution failures print the complete partial report
to stdout and a short diagnostic to stderr. Input and connection failures occur
before execution and produce an error on stderr. Inspect partial results before
re-running a plan that mutates state.

## Validation and reproducible metrics

```bash
swift test --package-path Packages/macOS/CmuxFoundation --filter CmuxRPCBatchTests
CMUX_CLI_BIN=/path/to/built/cmux python3 tests/test_cli_rpc_batch.py
python3 scripts/benchmark-rpc-batch.py --cli /path/to/built/cmux --label full-built-cli
```

The benchmark uses an isolated mock Unix socket server, 50 small `window.list`
requests per workflow, one excluded warmup, and seven alternating paired rounds.
It reports all timing samples, median elapsed time, process counts, and observed
connection counts. It measures client orchestration overhead, not app execution
or rendering. There is no machine-dependent performance threshold in tests.

When the full app toolchain is unavailable, a focused harness compiles the actual
batch core, Swift tests, and CLI adapter directly:

```bash
./scripts/test-rpc-batch-focused.sh --benchmark
```

That harness substitutes the outer command host and socket transport. Its results
are labeled `focused-adapter-harness` and must not be reported as full cmux app or
CLI performance. The normal CI lane runs the Python contract tests against the
full built CLI; the package CI lane runs the Swift tests.
