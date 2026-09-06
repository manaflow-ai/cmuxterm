#!/usr/bin/env python3
"""Validate the Rust CLI migration manifest before a cutover or release."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "docs/cli-rust-parity-manifest.json"
ALLOWED = {"pending", "partial", "complete"}


def main() -> int:
    try:
        document = json.loads(MANIFEST.read_text())
    except (OSError, json.JSONDecodeError) as error:
        print(f"error: cannot read {MANIFEST}: {error}", file=sys.stderr)
        return 2

    families = document.get("families")
    if not isinstance(families, list) or not families:
        print("error: parity manifest has no families", file=sys.stderr)
        return 2

    failures: list[str] = []
    seen: set[str] = set()
    for family in families:
        family_id = family.get("id", "<missing>")
        status = family.get("status")
        commands = family.get("commands")
        evidence = family.get("evidence")
        if status not in ALLOWED:
            failures.append(f"{family_id}: invalid status {status!r}")
        if not isinstance(commands, list) or not commands:
            failures.append(f"{family_id}: commands must be a non-empty list")
        if not isinstance(evidence, list) or not evidence:
            failures.append(f"{family_id}: evidence must be a non-empty list")
        if family_id in seen:
            failures.append(f"duplicate family id: {family_id}")
        seen.add(family_id)
        for command in commands or []:
            if not isinstance(command, str) or not command.strip():
                failures.append(f"{family_id}: invalid command entry")

    if failures:
        for failure in failures:
            print(f"error: {failure}", file=sys.stderr)
        return 1

    incomplete = [family["id"] for family in families if family["status"] != "complete"]
    print(f"Rust CLI parity manifest valid: {len(families)} families")
    if incomplete:
        print(f"cutover blocked: {len(incomplete)} families incomplete ({', '.join(incomplete)})")
        return 3
    print("cutover allowed: every family is complete")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
