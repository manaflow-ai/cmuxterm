#!/usr/bin/env python3
"""Regression coverage for Claude children after macOS purges ``$TMPDIR``."""

from __future__ import annotations

import os
import re
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path

from node_runtime import ensure_node_on_path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_WRAPPER = ROOT / "Resources" / "bin" / "cmux-claude-wrapper"


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def wait_for_text(path: Path, timeout: float = 10.0) -> str:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            value = path.read_text(encoding="utf-8").strip()
            if value:
                return value
        time.sleep(0.02)
    raise TimeoutError(f"timed out waiting for {path}")


def main() -> int:
    node_path = ensure_node_on_path()
    if node_path is None:
        print("SKIP: node runtime not found; Claude child probe requires node")
        return 0

    with tempfile.TemporaryDirectory(prefix="cmux-claude-wrapper-tmpdir-purge-") as td:
        root = Path(td)
        wrapper_dir = root / "cmux.app" / "Contents" / "Resources" / "bin"
        real_dir = root / "real-bin"
        home_dir = root / "home with spaces"
        session_tmpdir = root / "session-tmp"
        wrapper_dir.mkdir(parents=True)
        real_dir.mkdir()
        home_dir.mkdir()
        session_tmpdir.mkdir()

        wrapper = wrapper_dir / "cmux-claude-wrapper"
        shutil.copy2(SOURCE_WRAPPER, wrapper)
        wrapper.chmod(0o755)

        ready_path = root / "ready"
        continue_path = root / "continue"
        make_executable(
            real_dir / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "${NODE_OPTIONS-__UNSET__}" > "$FAKE_READY_PATH"
while [[ ! -e "$FAKE_CONTINUE_PATH" ]]; do
  sleep 0.02
done
exec node -e 'process.stdout.write("node-child-survived")'
""",
        )
        make_executable(
            wrapper_dir / "cmux",
            """#!/usr/bin/env bash
set -euo pipefail
exit 0
""",
        )

        socket_path = root / "cmux.sock"
        test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        test_socket.bind(str(socket_path))
        try:
            environment = {
                key: value
                for key, value in os.environ.items()
                if not key.startswith("CMUX_") and key not in {"NODE_OPTIONS", "XDG_CACHE_HOME"}
            }
            environment.update(
                {
                    "PATH": f"{Path(node_path).parent}:{wrapper_dir}:{real_dir}:/usr/bin:/bin",
                    "HOME": str(home_dir),
                    "TMPDIR": str(session_tmpdir),
                    "CMUX_SURFACE_ID": "surface:test",
                    "CMUX_SOCKET_PATH": str(socket_path),
                    "CMUX_BUNDLED_CLI_PATH": str(wrapper_dir / "cmux"),
                    "CMUX_CUSTOM_CLAUDE_PATH": str(real_dir / "claude"),
                    "FAKE_READY_PATH": str(ready_path),
                    "FAKE_CONTINUE_PATH": str(continue_path),
                }
            )
            process = subprocess.Popen(
                [str(wrapper), "hello"],
                cwd=root,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

            try:
                node_options = wait_for_text(ready_path)
                match = re.search(r'--require="([^"]+)"|--require=(\S+)', node_options)
                if match is None:
                    continue_path.touch()
                    process.kill()
                    stdout, stderr = process.communicate()
                    print(f"FAIL: wrapped Claude did not receive a restore preload: {node_options!r}")
                    return 1

                restore_path = Path(match.group(1) or match.group(2))
                legacy_root = session_tmpdir / "cmux-claude-node-options"
                shutil.rmtree(legacy_root, ignore_errors=True)
                continue_path.touch()
                stdout, stderr = process.communicate(timeout=10)
            except (TimeoutError, subprocess.TimeoutExpired) as exc:
                process.kill()
                stdout, stderr = process.communicate()
                print(f"FAIL: wrapped Claude child did not finish after TMPDIR purge: {exc}")
                print(f"stdout={stdout!r}")
                print(f"stderr={stderr!r}")
                return 1
        finally:
            test_socket.close()

    if process.returncode != 0:
        print("FAIL: Node child died after the restore shim's TMPDIR directory was purged")
        print(f"exit={process.returncode}")
        print(f"stdout={stdout!r}")
        print(f"stderr={stderr!r}")
        return 1
    if stdout != "node-child-survived":
        print(f"FAIL: unexpected child output after TMPDIR purge: {stdout!r}")
        return 1
    if str(restore_path).startswith(str(session_tmpdir)):
        print(f"FAIL: restore shim still lives under TMPDIR: {restore_path}")
        return 1

    print("PASS: Claude Node children survive a TMPDIR purge")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
