#!/usr/bin/env python3
"""Validate the Rust CLI migration manifest before a cutover or release."""

from __future__ import annotations

import json
import hashlib
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "docs/cli-rust-parity-manifest.json"
INVENTORY = ROOT / "docs/cli-rust-command-inventory.json"
SOURCE = ROOT / "CLI/cmux.swift"
ALLOWED = {"pending", "partial", "complete"}


def main() -> int:
    try:
        document = json.loads(MANIFEST.read_text())
    except (OSError, json.JSONDecodeError) as error:
        print(f"error: cannot read {MANIFEST}: {error}", file=sys.stderr)
        return 2

    try:
        inventory = json.loads(INVENTORY.read_text())
        source_hash = hashlib.sha256(SOURCE.read_bytes()).hexdigest()
    except (OSError, json.JSONDecodeError) as error:
        print(f"error: cannot read source inventory: {error}", file=sys.stderr)
        return 2

    if inventory.get("source_sha256") != source_hash:
        print(
            "error: source-derived CLI inventory is stale; run "
            "scripts/generate-cli-rust-command-inventory.py",
            file=sys.stderr,
        )
        return 1
    inventory_commands = inventory.get("commands")
    if not isinstance(inventory_commands, list) or not inventory_commands:
        print("error: source inventory has no dispatch commands", file=sys.stderr)
        return 1
    inventory_labels = [
        label
        for entry in inventory_commands
        for label in [entry.get("command"), *(entry.get("aliases") or [])]
    ]
    if any(not isinstance(label, str) or not label.strip() for label in inventory_labels):
        print("error: source inventory contains an invalid command label", file=sys.stderr)
        return 1
    if len(inventory_labels) != len(set(inventory_labels)):
        print("error: source inventory contains duplicate command labels", file=sys.stderr)
        return 1

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
    print(
        f"Rust CLI parity manifest valid: {len(families)} families; "
        f"{len(inventory_commands)} Swift dispatch arms; "
        f"{len(inventory_labels)} command labels"
    )
    if incomplete:
        print(f"cutover blocked: {len(incomplete)} families incomplete ({', '.join(incomplete)})")
        return 3
    print("cutover allowed: every family is complete")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
