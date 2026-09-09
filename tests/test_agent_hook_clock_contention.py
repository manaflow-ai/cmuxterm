#!/usr/bin/env python3
"""Exercise generated hooks while another callback owns the ordering clock."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import subprocess
import tempfile
from pathlib import Path

from node_runtime import ensure_node_on_path
from test_claude_wrapper_hooks import parse_settings_arg, run_wrapper


def check_contended_hook(command: str, environment: dict[str, str], root: Path) -> None:
    clock = root / "cmux-agent-hook-clock-v2"
    clock.mkdir(mode=0o700)
    capture = root / "captured-time"
    fake_cli = root / "fake cmux"
    fake_cli.write_text(
        '#!/bin/sh\ncat >/dev/null\nprintf "%s\\n" "$CMUX_AGENT_HOOK_CAPTURED_AT" '
        '> "$CMUX_TEST_CAPTURE"\nprintf "{}\\n"\n',
        encoding="utf-8",
    )
    fake_cli.chmod(0o700)
    environment.update(
        TMPDIR=str(root),
        CMUX_SURFACE_ID="22222222-2222-2222-2222-222222222222",
        CMUX_BUNDLED_CLI_PATH=str(fake_cli),
        CMUX_CLAUDE_HOOK_CMUX_BIN=str(fake_cli),
        CMUX_TEST_CAPTURE=str(capture),
    )
    baseline = subprocess.run(
        ["/bin/sh", "-c", command], env=environment, input="{}",
        capture_output=True, text=True, timeout=10,
    )
    assert baseline.returncode == 0 and capture.is_file(), (
        "Uncontended hook failed before the lock test", baseline.stdout, baseline.stderr
    )
    prior_time = float(capture.read_text(encoding="utf-8").strip())
    assert prior_time >= 946684800
    capture.unlink()

    # This is a real held BSD file lock, not a timing-based contention guess.
    # The completion deadline asserts the callback waits instead of dropping.
    with (clock / "lock").open("a") as owner:
        fcntl.flock(owner, fcntl.LOCK_EX)
        process = subprocess.Popen(
            ["/bin/sh", "-c", command],
            env=environment,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        try:
            try:
                stdout, stderr = process.communicate("{}", timeout=1)
            except subprocess.TimeoutExpired:
                pass
            else:
                raise AssertionError(
                    "Hook completed while the ordering clock was locked; "
                    f"the callback was dropped or emitted an unordered event: {stdout!r} {stderr!r}"
                )
            finally:
                fcntl.flock(owner, fcntl.LOCK_UN)

            stdout, stderr = process.communicate(timeout=10)
            assert process.returncode == 0, (stdout, stderr)
            assert capture.is_file(), "The callback was not delivered after the clock became available"
            value = capture.read_text(encoding="utf-8").strip()
            assert float(value) > prior_time, f"Callback received a stale capture time: {value!r}"
        finally:
            if process.poll() is None:
                # Only the session started above belongs to this test.
                import signal

                os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=5)


def isolated_environment(root: Path) -> dict[str, str]:
    return {
        "HOME": str(root),
        "CFFIXED_USER_HOME": str(root),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "CMUX_CLI_SENTRY_DISABLED": "1",
    }


def check_claude_hooks() -> None:
    assert ensure_node_on_path() is not None, "The wrapper behavior fixture requires Node.js"
    code, argv, _, stderr, *_ = run_wrapper(socket_state="live", argv=["-p", "hello"])
    assert code == 0, stderr
    hooks = parse_settings_arg(argv)["hooks"]
    for event, invocation in (
        ("Stop", "hooks claude stop"),
        ("SessionEnd", "hooks claude session-end"),
        ("PermissionRequest", "hooks feed --source claude"),
    ):
        commands = [hook["command"] for group in hooks[event] for hook in group["hooks"]]
        command = next(command for command in commands if invocation in command)
        with tempfile.TemporaryDirectory(prefix="cmux hook clock contention ") as directory:
            root = Path(directory)
            check_contended_hook(command, isolated_environment(root), root)
        print(f"PASS: Claude {event} waits for the clock and delivers its captured event")


def check_codex_hook(cli: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux codex clock contention ") as directory:
        root = Path(directory)
        codex_home = root / ".codex"
        codex_home.mkdir()
        environment = isolated_environment(root)
        environment["CODEX_HOME"] = str(codex_home)
        subprocess.run(
            [str(cli), "hooks", "codex", "install", "--yes"],
            env=environment, capture_output=True, text=True, check=True, timeout=15,
        )
        hooks = json.loads((codex_home / "hooks.json").read_text(encoding="utf-8"))["hooks"]
        command = hooks["PermissionRequest"][0]["hooks"][0]["command"]
        check_contended_hook(command, environment, root)
    print("PASS: installed Codex hook waits for the clock and delivers its captured event")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, help="Also exercise hooks installed by this built CLI")
    arguments = parser.parse_args()
    check_claude_hooks()
    if arguments.cli:
        check_codex_hook(arguments.cli.resolve())
