#!/usr/bin/env python3
"""
Regression coverage for Codex hook layering.

Codex appends cmux's session-flags layer to hooks.json, so copying user-owned
hook groups into the injected values would register and run them twice (#12081).
This test guards that contract and the one-cmux-producer-per-event rule.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

from claude_teams_test_utils import resolve_cmux_cli


CODEX_EVENTS = (
    "PreToolUse",
    "PermissionRequest",
    "PostToolUse",
    "PreCompact",
    "PostCompact",
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
    "SubagentStart",
    "SubagentStop",
    "Stop",
    "Interrupt",
)

VALUE_PATTERN = re.compile(r"^hooks\.([A-Za-z]+)=(.*)$")
SHAPE_PATTERN = re.compile(
    r"^\[\{hooks=\[\{type=\"command\",command='''(?P<cmd>[^']+)''',timeout=\d+\}\]\}\]$"
)


def run_inject_args(cli: str, codex_home: str) -> list[str]:
    env = os.environ.copy()
    env["CODEX_HOME"] = codex_home
    for key in list(env):
        if key.startswith("CMUX_"):
            del env[key]
    result = subprocess.run(
        [cli, "hooks", "codex", "inject-args"],
        env=env,
        check=True,
        stdout=subprocess.PIPE,
    )
    return [part.decode("utf-8") for part in result.stdout.split(b"\0") if part]


def user_hook_group(event: str) -> dict[str, object]:
    return {
        "matcher": "",
        "hooks": [
            {
                "type": "command",
                "command": "user-{}-hook".format(event),
                "timeout": 7,
            }
        ],
    }


def write_hooks(home: Path, hooks: dict[str, list[dict[str, object]]]) -> bytes:
    home.mkdir(parents=True, exist_ok=True)
    path = home / "hooks.json"
    path.write_text(json.dumps({"hooks": hooks}, indent=2) + "\n", encoding="utf-8")
    return path.read_bytes()


def emitted_hooks(
    args: list[str], require_session_start: bool = True
) -> tuple[dict[str, str], dict[str, str]]:
    if args[:3] != ["--enable", "hooks", "--dangerously-bypass-hook-trust"]:
        raise AssertionError("unexpected activation args: {!r}".format(args[:3]))
    rest = args[3:]
    if len(rest) % 2 != 0 or any(rest[index] != "-c" for index in range(0, len(rest), 2)):
        raise AssertionError("expected only -c/value pairs: {!r}".format(rest))

    values: dict[str, str] = {}
    commands: dict[str, str] = {}
    for index in range(1, len(rest), 2):
        value = rest[index]
        match = VALUE_PATTERN.fullmatch(value)
        if match is None:
            raise AssertionError("invalid hook value: {!r}".format(value))
        event, encoded = match.groups()
        if event in values:
            raise AssertionError("duplicate emitted event: {}".format(event))
        if "user-" in value:
            raise AssertionError("user-owned hook copied into value: {!r}".format(value))
        shape = SHAPE_PATTERN.fullmatch(encoded)
        if shape is None:
            raise AssertionError("unexpected cmux hook shape: {!r}".format(value))
        command = shape.group("cmd")
        command_path = Path(command)
        if not (
            (command_path.name.startswith("cmux-codex-hook-") and command_path.name.endswith(".sh"))
            or "cmux hooks codex" in command
        ):
            raise AssertionError("non-cmux command emitted: {!r}".format(command))
        values[event] = encoded
        commands[event] = command
    required = {"UserPromptSubmit", "Stop"}
    if require_session_start:
        required.add("SessionStart")
    if not required.issubset(values):
        raise AssertionError("missing required events: {!r}".format(sorted(required - set(values))))
    return values, commands


def main() -> int:
    cli = resolve_cmux_cli()
    with tempfile.TemporaryDirectory(prefix="cmux-codex-inject-args-", dir="/tmp") as root:
        root_path = Path(root)
        first_home = root_path / "case-one"
        first_hooks = {event: [user_hook_group(event)] for event in CODEX_EVENTS}
        first_bytes = write_hooks(first_home, first_hooks)
        first_args = run_inject_args(cli, str(first_home))
        first_values, first_commands = emitted_hooks(first_args)
        if (first_home / "hooks.json").read_bytes() != first_bytes:
            raise AssertionError("case 1 changed hooks.json")
        session_start_command = first_commands["SessionStart"]

        second_home = root_path / "case-two"
        second_hooks = {event: [user_hook_group(event)] for event in CODEX_EVENTS}
        second_hooks["SessionStart"].append(
            {"hooks": [{"type": "command", "command": session_start_command}]}
        )
        second_bytes = write_hooks(second_home, second_hooks)
        second_args = run_inject_args(cli, str(second_home))
        second_values, _ = emitted_hooks(second_args, require_session_start=False)
        if "SessionStart" in second_values:
            raise AssertionError("persistent cmux SessionStart handler was not respected")
        if not {"UserPromptSubmit", "Stop"}.issubset(second_values):
            raise AssertionError("case 2 omitted required remaining events")
        if (second_home / "hooks.json").read_bytes() != second_bytes:
            raise AssertionError("case 2 changed hooks.json")

    print("PASS: Codex inject-args preserves user groups and one cmux producer per event")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print("FAIL: {}".format(exc))
        raise SystemExit(1)
