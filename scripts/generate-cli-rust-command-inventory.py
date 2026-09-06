#!/usr/bin/env python3
"""Generate the source-derived Swift CLI dispatch inventory.

The migration must account for every top-level command arm in the Swift CLI.
This file is generated from the main `switch command` in `CLI/cmux.swift`; it
is a discovery index, not a replacement for behavior conformance evidence.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "CLI/cmux.swift"
OUTPUT = ROOT / "docs/cli-rust-command-inventory.json"
SWITCH_START = "        switch command {"
SWITCH_END = "            throw unknownCommandError(command)\n        }\n        } catch {"


def extract_commands(source: str) -> tuple[int, int, list[dict[str, object]]]:
    run_offset = source.index("func run() async throws")
    start_offset = source.index(SWITCH_START, run_offset)
    end_offset = source.index(SWITCH_END, start_offset)
    block = source[start_offset:end_offset]
    start_line = source[:start_offset].count("\n") + 1
    commands: list[dict[str, object]] = []
    pending: str | None = None
    pending_line = 0

    def finish(expression: str, line: int) -> None:
        labels = re.findall(r'"((?:\\.|[^"\\])*)"', expression)
        if not labels:
            raise ValueError(f"cannot parse command case at source line {line}")
        commands.append(
            {
                "command": labels[0],
                "aliases": labels[1:],
                "source_line": line,
                "source_case": expression.strip(),
                "status": "pending",
            }
        )

    for offset, raw_line in enumerate(block.splitlines()):
        line_number = start_line + offset
        line = raw_line.rstrip()
        if line.startswith("        case "):
            if pending is not None:
                raise ValueError(f"unterminated command case at source line {pending_line}")
            pending = line[len("        case ") :]
            pending_line = line_number
            if ":" in pending:
                finish(pending, pending_line)
                pending = None
        elif pending is not None and re.fullmatch(r'\s*"(?:\\.|[^"\\])*",?', line):
            pending += " " + line.strip()
        elif pending is not None and line.strip().endswith(":"):
            pending += " " + line.strip()
            finish(pending, pending_line)
            pending = None

    if pending is not None:
        raise ValueError(f"unterminated command case at source line {pending_line}")
    return start_line, start_line + block.count("\n"), commands


def generate() -> dict[str, object]:
    source_bytes = SOURCE.read_bytes()
    source = source_bytes.decode("utf-8")
    start_line, end_line, commands = extract_commands(source)
    return {
        "schema": 1,
        "generated_by": "scripts/generate-cli-rust-command-inventory.py",
        "source_file": str(SOURCE.relative_to(ROOT)),
        "source_sha256": hashlib.sha256(source_bytes).hexdigest(),
        "dispatch_anchor": {
            "start_line": start_line,
            "end_line": end_line,
            "marker": "switch command -> unknownCommandError(command)",
        },
        "commands": commands,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail if the checked-in file is stale")
    args = parser.parse_args()
    document = generate()
    rendered = json.dumps(document, indent=2, sort_keys=False) + "\n"
    if args.check:
        try:
            current = OUTPUT.read_text()
        except OSError as error:
            parser.error(f"cannot read {OUTPUT}: {error}")
        if current != rendered:
            print(f"stale generated inventory: {OUTPUT}")
            return 1
    else:
        OUTPUT.write_text(rendered)
        print(f"generated {OUTPUT} ({len(document['commands'])} dispatch arms)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
