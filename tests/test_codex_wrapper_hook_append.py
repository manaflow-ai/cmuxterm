#!/usr/bin/env python3
"""Behavioral regression test for cmux Codex hook argument composition."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli


EVENT_COMMANDS = {
    "SessionStart": "user-session-start",
    "UserPromptSubmit": "user-prompt-submit",
    "Stop": "user-stop",
    "PreToolUse": "user-pre-tool-use",
    "PostToolUse": "user-post-tool-use",
    "PermissionRequest": "user-permission-request",
}


def run_inject_args(cli_path: str, codex_home: Path, home: Path) -> list[str]:
    environment = os.environ.copy()
    environment.update(
        {
            "CODEX_HOME": str(codex_home),
            "HOME": str(home),
            "CMUX_SURFACE_ID": "",
            "CMUX_SOCKET_PATH": "",
        }
    )
    result = subprocess.run(
        [cli_path, "hooks", "codex", "inject-args"],
        env=environment,
        capture_output=True,
        check=True,
    )
    return [argument.decode("utf-8") for argument in result.stdout.split(b"\0") if argument]


def test_injected_codex_hooks_append_to_user_hook_groups() -> None:
    cli_path = resolve_cmux_cli()
    with tempfile.TemporaryDirectory() as temporary_directory:
        root = Path(temporary_directory)
        codex_home = root / "codex"
        codex_home.mkdir()
        hooks = {
            "hooks": {
                event: [{"hooks": [{"type": "command", "command": command}]}]
                for event, command in EVENT_COMMANDS.items()
            }
        }
        (codex_home / "hooks.json").write_text(
            json.dumps(hooks),
            encoding="utf-8",
        )

        arguments = run_inject_args(cli_path, codex_home, root / "home")
        assignments = {
            arguments[index + 1][len("hooks.") :].split("=", 1)[0]: arguments[index + 1]
            for index, argument in enumerate(arguments[:-1])
            if argument == "-c" and arguments[index + 1].startswith("hooks.")
        }

        for event, command in EVENT_COMMANDS.items():
            assignment = assignments.get(event)
            assert assignment is not None, f"missing injected {event} assignment: {arguments}"
            assert command in assignment, f"user {event} hook was replaced: {assignment}"
            assert "cmux-codex-hook" in assignment, f"cmux {event} hook was not appended: {assignment}"


if __name__ == "__main__":
    test_injected_codex_hooks_append_to_user_hook_groups()
    print("PASS: Codex wrapper hook arrays preserve user handlers")
