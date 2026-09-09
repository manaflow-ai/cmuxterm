#!/usr/bin/env python3
"""Exercise the trusted CI gate through its executable result contract."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "ci" / "verify_required_ci_run.py"
HEAD = "a" * 40


def run_gate(**overrides: str) -> subprocess.CompletedProcess[str]:
    inputs = {
        "expected-sha": HEAD,
        "ci-sha": HEAD,
        "ci-result": "success",
        "route-result": "success",
        "browser-required": "true",
        "browser-result": "success",
    }
    inputs.update(overrides)
    return subprocess.run(
        [sys.executable, str(HELPER), *[part for key, value in inputs.items() for part in (f"--{key}", value)]],
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )


def test_exact_head_with_successful_trusted_jobs_passes() -> None:
    result = run_gate()
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "required CI verification passed"


def test_unrequired_browser_lane_may_be_skipped() -> None:
    result = run_gate(**{"browser-required": "false", "browser-result": "skipped"})
    assert result.returncode == 0, result.stderr


def test_incomplete_or_unsuccessful_trusted_jobs_never_pass() -> None:
    for field in ("ci-result", "route-result", "browser-result"):
        for status in ("failure", "cancelled", "skipped", "pending", "unknown", ""):
            result = run_gate(**{field: status})
            assert result.returncode == 1, (field, status, result)
            assert "required CI verification failed" in result.stderr


def test_missing_or_stale_source_identity_never_passes() -> None:
    for field in ("expected-sha", "ci-sha"):
        for sha in ("", "main", "a" * 7, "z" * 40, "b" * 40):
            result = run_gate(**{field: sha})
            assert result.returncode == 1, (field, sha, result)


def test_unknown_browser_route_never_passes() -> None:
    for route in ("", "unknown", "True", "success"):
        result = run_gate(**{"browser-required": route})
        assert result.returncode == 1, (route, result)


def test_unrequired_browser_lane_cannot_hide_failure() -> None:
    for status in ("failure", "cancelled", "unknown", ""):
        result = run_gate(**{"browser-required": "false", "browser-result": status})
        assert result.returncode == 1, (status, result)


def test_missing_inputs_fail_closed() -> None:
    result = subprocess.run(
        [sys.executable, str(HELPER)], capture_output=True, text=True, check=False, timeout=10,
    )
    assert result.returncode != 0


if __name__ == "__main__":
    for name, value in sorted(globals().items()):
        if name.startswith("test_") and callable(value):
            value()
    print("PASS: trusted CI result contract")
