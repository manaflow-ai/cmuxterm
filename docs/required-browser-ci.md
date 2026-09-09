# Required browser CI rollout (maintainer runbook)

This change is **not fully enforced by a required check name**. Before declaring
the incident closed, an organization administrator must require the workflow
itself and complete the negative tests below. Do not merge this PR as a claim
that those activation tests have already passed.

## Trust boundary

Configure an organization **Require workflows to pass before merging** rule for
`manaflow-ai/cmux`, targeting only `refs/heads/main`. Select this repository's
`.github/workflows/required-ci.yml` from a reviewed immutable revision, then its
protected `main` revision after rollout. The organization rule must have no
automation/user bypass. A normal `required-ci` or `ci-status` check is not a
substitute for a required workflow: a PR can rewrite its YAML and emit a no-op
check with either name.

The required workflow directly calls CI and browser E2E from its own workflow
revision. CI checks out the exact PR head in every source job (including fork
repositories) and returns that SHA. The final gate consumes GitHub's `needs`
results from these calls, not an API search for a conveniently named job. It
rejects unsuccessful/skipped CI, stale or missing source identity, unresolved
routing, and unsuccessful required browser verification.

Use `pull_request`, not `pull_request_target`, for execution of PR build/test
code. No secrets are inherited by the reusable jobs, checkout credentials are
not persisted, and the fork token/cache/approval restrictions remain in force.
PR tests/build scripts remain reviewable source code: this is not proof against
a deliberately falsified test body. Native-browser changes still require real
native runtime evidence, not a fallback smoke pass.

Ghostty pins are read as data from the same immutable source tree as the
submodule. Downloader and archive-validator code remain sourced from the
trusted workflow revision. This permits a legitimate revision-plus-pin bump
without accepting executable download tooling from the PR.

## Activation and acceptance

1. Keep this PR unmerged until its normal checks and exact-HEAD browser run pass.
2. An organization administrator creates the required-workflow rule in
   **Evaluate** mode, scoped only to this repository/main, at the reviewed
   candidate workflow revision. Existing PRs may need a new synchronize event
   (or reopen) to exercise a newly installed rule.
3. Verify an actual ruleset run, not only an ordinary PR run with the same name.
   Preserve its run ID, selected workflow revision, source SHA, and job evidence.
4. In an authorized disposable PR, replace candidate `ci.yml` with a successful
   no-op `ci-status`. The ruleset must still run the trusted compile, typecheck,
   unit, guard and browser jobs. A failing source test must block merge even
   when the fake candidate status passes.
5. Exercise a fork PR whose Actions `pull_requests` metadata is empty, and a
   legitimate Ghostty revision-plus-checksum bump. Both must reach the real
   workloads; a wrong/missing checksum must fail closed.
6. Verify zero selected tests, a missing CEF framework/helper, and a stale
   source-SHA artifact each fail the gate. Native CEF coverage requires a tree
   containing CEF; the reverted fallback tree cannot provide it.
7. Enable strict up-to-date status checks and activate the required-workflow
   rule without bypass. Re-check current HEAD/base before an authorized merge.
8. After landing, move the rule's source to protected main and repeat the
   no-op-workflow negative test. Preserve existing CLA and other required rules.

## Explicit trade-offs and limits

- The trusted CI call runs every workload; a PR-owned change-area detector
  cannot silently skip one. Ordinary candidate CI remains for compatibility
  with existing `ci-status` protection, so rollout temporarily duplicates work.
  Removing that duplication requires a separately verified protection migration.
- Browser verification uses a paid ephemeral macOS runner. Compile-only checks
  cannot establish render, interaction, screenshot, reopen or cleanup behavior.
- Organization-level policy is external state. This PR cannot prevent an
  administrator from restoring bypass, disabling strictness, or removing the
  required workflow. Check live policy before claiming the gate is enforced.
- Without the organization-required workflow and its negative tests, this PR
  is **not at the merge/incident-close bar**, regardless of green named checks.

References: GitHub Docs, "Available rules for rulesets" (require workflows),
"Troubleshooting rules" (ruleset workflow activation), and "Securely using
pull_request_target". The PR records the applicable documentation and rollout
evidence; this file is an internal maintainer runbook, not localized product UI.
