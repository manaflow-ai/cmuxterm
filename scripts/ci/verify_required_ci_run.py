#!/usr/bin/env python3
"""Verify exact-head results supplied by the ruleset-controlled CI workflow.

Inputs must come from GitHub's ``needs`` context in an enforced required
workflow, never from a PR comment, a check name, or a PR-owned workflow run.
The organization ruleset supplies the trusted workflow identity; this helper
only validates its result and source-identity contract.
"""

from __future__ import annotations

import argparse
import re
import sys
from typing import Iterable


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for field in (
        "expected-sha", "ci-sha", "ci-result", "route-result", "browser-required", "browser-result",
    ):
        parser.add_argument(f"--{field}", required=True)
    args = parser.parse_args(list(argv) if argv is not None else None)
    passed = (
        re.fullmatch(r"[0-9a-f]{40}", args.expected_sha) is not None
        and args.ci_sha == args.expected_sha
        and args.ci_result == "success"
        and args.route_result == "success"
        and args.browser_required in {"true", "false"}
        and (
            args.browser_result == "success"
            or (args.browser_required == "false" and args.browser_result == "skipped")
        )
    )
    if not passed:
        print("::error::required CI verification failed", file=sys.stderr)
        return 1
    print("required CI verification passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
