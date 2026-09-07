#!/usr/bin/env python3
"""Behavioral batch CLI contract tests against an isolated Unix socket server.

Set CMUX_CLI_BIN to the built cmux CLI. The focused build script can also run
these tests against the production adapter with a test-only socket transport.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest


class BatchServer:
    def __init__(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cmux-batch-", dir="/tmp")
        self.path = str(Path(self.temp.name) / "rpc.sock")
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.path)
        self.listener.listen()
        self.listener.settimeout(0.1)
        self.stop = threading.Event()
        self.connections = 0
        self.requests = []
        self.errors = []
        self.thread = threading.Thread(target=self.serve, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def serve(self):
        try:
            while not self.stop.is_set():
                try:
                    conn, _ = self.listener.accept()
                except socket.timeout:
                    continue
                self.connections += 1
                with conn, conn.makefile("rb") as stream:
                    conn.settimeout(3)
                    for line in stream:
                        # The production CLI may authenticate from its environment.
                        if line.startswith(b"auth "):
                            conn.sendall(b"OK\n")
                            continue
                        request = json.loads(line)
                        self.requests.append(request)
                        method = request["method"]
                        if method == "test.disconnect":
                            break
                        if method == "test.fail":
                            response = {"id": request["id"], "ok": False,
                                        "error": {"code": "not_found", "message": "Missing resource"}}
                        else:
                            response = {"id": request["id"], "ok": True, "result": {
                                "workspace_id": "test-workspace-uuid", "echo": request.get("params", {})}}
                        conn.sendall(json.dumps(response).encode() + b"\n")
        except Exception as error:
            self.errors.append(error)

    def __exit__(self, *_):
        self.stop.set()
        self.thread.join(timeout=5)
        self.listener.close()
        self.temp.cleanup()
        if self.thread.is_alive():
            raise AssertionError("Mock socket server did not stop")
        if self.errors:
            raise self.errors[0]


class RPCBatchCLITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cli = os.environ["CMUX_CLI_BIN"]

    def run_cli(self, args, data=""):
        env = {k: v for k, v in os.environ.items() if not k.startswith(("CMUX_", "CMUXD_"))}
        return subprocess.run([self.cli, *args], input=data, capture_output=True,
                              text=True, timeout=15, env=env)

    def test_help_without_socket(self):
        result = self.run_cli(["--socket", "/tmp/cmux-batch-absent.sock", "rpc-batch", "--help"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--dry-run", result.stdout)

    def test_dry_run_without_socket_from_stdin_and_file(self):
        data = json.dumps([{"id": "read", "method": "window.list"}])
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "plan.json"
            path.write_text(data)
            for source in ["-", str(path)]:
                with self.subTest(source=source):
                    result = self.run_cli(["--socket", "/tmp/cmux-batch-absent.sock", "rpc-batch", source, "--dry-run"], data)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(json.loads(result.stdout), {"ok": True, "dry_run": True, "requests": 1})

    def test_invalid_trailing_request_sends_nothing(self):
        with BatchServer() as server:
            result = self.run_cli(["--socket", server.path, "rpc-batch", "-"],
                                  '[{"id":"a","method":"workspace.create"},{"id":"b"}]')
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(server.connections, 0)
            self.assertEqual(server.requests, [])

    def test_invalid_inputs_and_options_are_usage_errors(self):
        for args, data in [
            (["-"], "[]"), (["-"], " " * (1_048_576 + 1)),
            (["-", "--unknown"], "[]"), ([], ""),
            (["/tmp/cmux-batch-no-such-file.json"], ""),
            (["/tmp"], ""), (["-", "extra.json"], "[]"),
        ]:
            with self.subTest(args=args, bytes=len(data)):
                result = self.run_cli(["rpc-batch", *args], data)
                self.assertEqual(result.returncode, 2, result.stderr)

    def test_global_target_and_format_flags_are_rejected_before_connect(self):
        for flag, value in [("--window", "window:1"), ("--id-format", "refs")]:
            with self.subTest(flag=flag), BatchServer() as server:
                result = self.run_cli(["--socket", server.path, flag, value, "rpc-batch", "-"],
                                      '[{"id":"a","method":"window.list"}]')
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(server.connections, 0)

    def test_one_connection_ordered_calls_and_resolved_targets(self):
        data = json.dumps([
            {"id": "create", "method": "workspace.create", "params": {"title": "Batch demo"}},
            {"id": "rename", "method": "workspace.rename", "params": {
                "workspace_id": {"$ref": "create#/workspace_id"}, "title": "Ready"}},
            {"id": "read", "method": "window.list"},
        ])
        with BatchServer() as server:
            result = self.run_cli(["--socket", server.path, "rpc-batch", "-", "--json"], data)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(result.stdout)
            self.assertTrue(report["ok"])
            self.assertEqual(report["metrics"]["attempted"], 3)
            self.assertEqual(report["metrics"]["succeeded"], 3)
            self.assertEqual(server.connections, 1)
            self.assertEqual([r["method"] for r in server.requests],
                             ["workspace.create", "workspace.rename", "window.list"])
            self.assertEqual(server.requests[1]["params"]["workspace_id"], "test-workspace-uuid")
            self.assertEqual(report["results"][0]["result"]["workspace_id"], "test-workspace-uuid")
            self.assertGreaterEqual(report["metrics"]["duration_ms"], 0)

    def test_failure_modes_preserve_partial_results(self):
        for method, flag, expected in [
            ("test.fail", [], ["failed", "skipped", "skipped"]),
            ("test.fail", ["--continue-on-error"], ["failed", "failed", "succeeded"]),
            ("test.disconnect", ["--continue-on-error"], ["failed", "skipped", "skipped"]),
        ]:
            with self.subTest(method=method, flag=flag), BatchServer() as server:
                data = json.dumps([
                    {"id": "first", "method": method},
                    {"id": "dependent", "method": "workspace.rename", "params": {"workspace_id": {"$ref": "first#/workspace_id"}}},
                    {"id": "independent", "method": "window.list"},
                ])
                result = self.run_cli(["--socket", server.path, "rpc-batch", "-", *flag], data)
                self.assertEqual(result.returncode, 1, result.stderr)
                report = json.loads(result.stdout)
                self.assertFalse(report["ok"])
                self.assertEqual([r["status"] for r in report["results"]], expected)
                self.assertEqual(len(server.requests), 2 if expected[-1] == "succeeded" else 1)
                self.assertEqual(server.connections, 1)


if __name__ == "__main__":
    unittest.main()
