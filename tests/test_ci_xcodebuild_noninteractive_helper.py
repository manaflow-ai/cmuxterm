#!/usr/bin/env python3
"""Behavioral guard for the CI xcodebuild prompt wrapper."""

from __future__ import annotations

import subprocess
import sys
import textwrap
import os
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "ci" / "xcodebuild_noninteractive.py"
PROMPT = "Press space to interact, D to debug, or any other key to quit"


def main() -> int:
    child = textwrap.dedent(
        f"""
        import sys
        import termios
        import tty

        prompt = {PROMPT!r}
        fd = sys.stdin.fileno()
        old = termios.tcgetattr(fd)
        tty.setraw(fd)
        try:
            for _ in range(2):
                print(prompt, flush=True)
                ch = sys.stdin.read(1)
                print('received=' + ch, flush=True)
                termios.tcflush(fd, termios.TCIFLUSH)
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
        raise SystemExit(7)
        """
    )
    result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )

    if result.returncode != 7:
        print(result.stdout, end="")
        print(result.stderr, end="", file=sys.stderr)
        print(f"FAIL: expected wrapped command exit 7, got {result.returncode}")
        return 1
    if result.stdout.count("received=q") != 2:
        print(result.stdout, end="")
        print("FAIL: helper did not answer each crash prompt with q")
        return 1

    timeout_child = textwrap.dedent(
        """
        import time
        print("ready", flush=True)
        time.sleep(10)
        """
    )
    timeout_env = {
        **os.environ,
        "CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS": "0.2",
    }
    timeout_result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", timeout_child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=5,
        env=timeout_env,
    )
    if timeout_result.returncode != 124:
        print(timeout_result.stdout, end="")
        print(timeout_result.stderr, end="", file=sys.stderr)
        print(f"FAIL: expected timeout exit 124, got {timeout_result.returncode}")
        return 1
    if "Idle timed out after 0.2s" not in timeout_result.stderr:
        print(timeout_result.stdout, end="")
        print(timeout_result.stderr, end="", file=sys.stderr)
        print("FAIL: helper did not report idle timeout")
        return 1

    keepalive_child = textwrap.dedent(
        """
        import time
        print("Test Case '-[cmuxTests.HungTests testForever]' started.", flush=True)
        for _ in range(40):
            print("2026-09-08 14:30:00 cmux DEV[1:2] [CloudVM] GET /api/vm not_signed_in 1ms", flush=True)
            time.sleep(0.05)
        raise SystemExit(0)
        """
    )
    # Without an ignore pattern every line is progress, so the keepalive child
    # runs to completion and exits 0 (the pre-fix behavior, kept for callers
    # that opt out).
    keepalive_counts_result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", keepalive_child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=15,
        env={
            **os.environ,
            # Leave enough startup headroom on loaded CI runners while still
            # exercising that frequent output resets the idle deadline.
            "CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS": "20",
            "CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_IGNORE_RE": "",
        },
    )
    if keepalive_counts_result.returncode != 0:
        print(keepalive_counts_result.stdout, end="")
        print(keepalive_counts_result.stderr, end="", file=sys.stderr)
        print(f"FAIL: without an ignore pattern the keepalive child should finish, got {keepalive_counts_result.returncode}")
        return 1
    # With the pattern the keepalive is not progress: the child idles out 0.3s
    # after its last real line even though it prints every 50ms.
    keepalive_ignored_result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", keepalive_child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=15,
        env={
            **os.environ,
            "CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS": "0.3",
            "CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_IGNORE_RE": r"\[CloudVM\] GET /api/vm ",
        },
    )
    if keepalive_ignored_result.returncode != 124:
        print(keepalive_ignored_result.stdout, end="")
        print(keepalive_ignored_result.stderr, end="", file=sys.stderr)
        print(f"FAIL: keepalive-only output must idle out, got {keepalive_ignored_result.returncode}")
        return 1
    if "Idle timed out after 0.3s" not in keepalive_ignored_result.stderr:
        print(keepalive_ignored_result.stderr, end="", file=sys.stderr)
        print("FAIL: helper did not report the keepalive idle timeout")
        return 1
    if keepalive_ignored_result.stdout.count("[CloudVM] GET /api/vm") >= 40:
        print("FAIL: helper let the keepalive child run to completion despite the ignore pattern")
        return 1
    invalid_pattern_result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", "print('x')"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=15,
        env={
            **os.environ,
            "CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS": "1",
            "CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_IGNORE_RE": "(",
        },
    )
    if invalid_pattern_result.returncode != 2 or "not a valid regex" not in invalid_pattern_result.stderr:
        print(invalid_pattern_result.stderr, end="", file=sys.stderr)
        print(f"FAIL: an invalid ignore pattern must fail closed with exit 2, got {invalid_pattern_result.returncode}")
        return 1

    heartbeat_result = subprocess.run(
        [
            sys.executable,
            str(HELPER),
            sys.executable,
            "-c",
            "import os, time; os.close(1); os.close(2); time.sleep(0.35)",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=5,
        env={
            **os.environ,
            "CMUX_XCODEBUILD_NONINTERACTIVE_HEARTBEAT_SECONDS": "0.1",
        },
    )
    if heartbeat_result.returncode != 0 or heartbeat_result.stdout.count(
        "[xcodebuild still running after"
    ) < 2:
        print(heartbeat_result.stdout, end="")
        print(heartbeat_result.stderr, end="", file=sys.stderr)
        print("FAIL: helper did not emit recurring heartbeats for a quiet child")
        return 1

    post_test_env = {
        **os.environ,
        "CMUX_XCODEBUILD_NONINTERACTIVE_POST_TEST_TIMEOUT_SECONDS": "0.2",
    }
    passing_post_test_child = textwrap.dedent(
        """
        import time
        print("Test Suite 'Selected tests' passed at now", flush=True)
        print("\\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds", flush=True)
        time.sleep(10)
        """
    )
    passing_post_test_result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", passing_post_test_child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=5,
        env=post_test_env,
    )
    if passing_post_test_result.returncode != 0:
        print(passing_post_test_result.stdout, end="")
        print(passing_post_test_result.stderr, end="", file=sys.stderr)
        print(
            "FAIL: expected post-test timeout after passing Selected tests summary to exit 0, "
            f"got {passing_post_test_result.returncode}"
        )
        return 1

    noisy_post_test_child = textwrap.dedent(
        """
        import time
        print("Test Suite 'Selected tests' passed at now", flush=True)
        print("\\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds", flush=True)
        for _ in range(20):
            print("post-summary-noise", flush=True)
            time.sleep(0.1)
        """
    )
    noisy_post_test_result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", noisy_post_test_child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=5,
        env=post_test_env,
    )
    if noisy_post_test_result.returncode != 0:
        print(noisy_post_test_result.stdout, end="")
        print(noisy_post_test_result.stderr, end="", file=sys.stderr)
        print(
            "FAIL: expected noisy post-test timeout after passing Selected tests summary "
            f"to exit 0, got {noisy_post_test_result.returncode}"
        )
        return 1
    failing_post_test_child = textwrap.dedent(
        """
        import time
        print("Test Suite 'Selected tests' failed at now", flush=True)
        print("\\t Executed 1 test, with 1 failure (1 unexpected) in 0.001 seconds", flush=True)
        time.sleep(10)
        """
    )
    failing_post_test_result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", failing_post_test_child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=5,
        env=post_test_env,
    )
    if failing_post_test_result.returncode != 125:
        print(failing_post_test_result.stdout, end="")
        print(failing_post_test_result.stderr, end="", file=sys.stderr)
        print(
            "FAIL: expected post-test timeout after failed Selected tests summary to exit 125, "
            f"got {failing_post_test_result.returncode}"
        )
        return 1

    mixed_framework_child = textwrap.dedent(
        """
        import time
        print("Test Suite 'Selected tests' passed at now", flush=True)
        print("\\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds", flush=True)
        print("Test run started.", flush=True)
        time.sleep(0.35)
        print("Test run with 1 test in 1 suite passed after 0.350 seconds.", flush=True)
        time.sleep(10)
        """
    )
    mixed_framework_result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", mixed_framework_child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=5,
        env=post_test_env,
    )
    if mixed_framework_result.returncode != 0:
        print(mixed_framework_result.stdout, end="")
        print(mixed_framework_result.stderr, end="", file=sys.stderr)
        print(
            "FAIL: expected the completed mixed-framework run to exit 0, "
            f"got {mixed_framework_result.returncode}"
        )
        return 1
    if "Test run with 1 test in 1 suite passed" not in mixed_framework_result.stdout:
        print(mixed_framework_result.stdout, end="")
        print(mixed_framework_result.stderr, end="", file=sys.stderr)
        print("FAIL: helper killed Swift Testing after the XCTest summary")
        return 1

    failing_mixed_framework_child = textwrap.dedent(
        """
        import time
        print("Test Suite 'Selected tests' passed at now", flush=True)
        print("\\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds", flush=True)
        print("Test run started.", flush=True)
        time.sleep(0.35)
        print("Test run with 1 test in 1 suite failed after 0.350 seconds.", flush=True)
        time.sleep(10)
        """
    )
    failing_mixed_framework_result = subprocess.run(
        [
            sys.executable,
            str(HELPER),
            sys.executable,
            "-c",
            failing_mixed_framework_child,
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=5,
        env=post_test_env,
    )
    if failing_mixed_framework_result.returncode != 125:
        print(failing_mixed_framework_result.stdout, end="")
        print(failing_mixed_framework_result.stderr, end="", file=sys.stderr)
        print(
            "FAIL: expected failed Swift Testing summary to exit 125, "
            f"got {failing_mixed_framework_result.returncode}"
        )
        return 1

    direct_output_child = "import sys; sys.stdout.write('x' * 262144); sys.stdout.flush()"
    direct_output_result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", direct_output_child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=5,
    )
    if direct_output_result.returncode != 0:
        print(direct_output_result.stdout, end="")
        print(direct_output_result.stderr, end="", file=sys.stderr)
        print(f"FAIL: expected direct output child exit 0, got {direct_output_result.returncode}")
        return 1
    if direct_output_result.stdout.count("x") != 262144:
        print(direct_output_result.stderr, end="", file=sys.stderr)
        print(
            f"FAIL: direct helper output was truncated to {direct_output_result.stdout.count('x')} bytes"
        )
        return 1

    with tempfile.TemporaryDirectory() as tmp:
        log_path = Path(tmp) / "helper.log"
        log_child = "print('child-log-line', flush=True)"
        log_result = subprocess.run(
            [sys.executable, str(HELPER), sys.executable, "-c", log_child],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
            env={
                **os.environ,
                "CMUX_XCODEBUILD_NONINTERACTIVE_LOG_PATH": str(log_path),
            },
        )
        if log_result.returncode != 0:
            print(log_result.stdout, end="")
            print(log_result.stderr, end="", file=sys.stderr)
            print(f"FAIL: expected log child exit 0, got {log_result.returncode}")
            return 1
        if "child-log-line" not in log_path.read_text():
            print(log_result.stdout, end="")
            print(log_result.stderr, end="", file=sys.stderr)
            print("FAIL: helper did not write child output to log path")
            return 1

    print(
        "PASS: xcodebuild noninteractive helper dismisses crash prompts, "
        "heartbeats quiet children, and idle-times out stuck children"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
