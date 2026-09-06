#!/usr/bin/env python3
"""
Smoke test for `cmux blueprint mcp`, the cmux-blueprint MCP server.

Uses the built cmux CLI when present (CMUX_CLI_BIN, CMUX_CLI, or the newest
DerivedData build) and skips otherwise. It drives only the stdio handshake
(initialize, tools/list, ping) and one tools/call outside a cmux terminal,
which must fail softly (isError) instead of killing the server. No app, no
socket, no GUI.
"""

from __future__ import annotations

import json
import os
import selectors
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EXPECTED_TOOLS = [
    "blueprint_state",
    "blueprint_show_mermaid",
    "blueprint_get",
    "blueprint_update",
    "blueprint_set_scene",
    "blueprint_export_image",
    "blueprint_show",
    "blueprint_hide",
]


def resolve_cmux_cli() -> Path | None:
    for env_key in ("CMUX_CLI_BIN", "CMUX_CLI"):
        value = os.environ.get(env_key)
        if value:
            candidate = Path(value)
            if candidate.is_file() and os.access(candidate, os.X_OK):
                return candidate
    derived = Path.home() / "Library" / "Developer" / "Xcode" / "DerivedData"
    candidates = sorted(
        derived.glob("*/Build/Products/Debug/cmux"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    return None


def read_json_line(proc: subprocess.Popen[str], timeout: float = 15.0) -> dict:
    assert proc.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    try:
        events = selector.select(timeout)
        if not events:
            raise TimeoutError("timed out waiting for cmux-blueprint MCP response")
        line = proc.stdout.readline()
    finally:
        selector.close()
    if not line:
        raise RuntimeError("cmux blueprint mcp exited before writing a response")
    return json.loads(line)


def send(proc: subprocess.Popen[str], payload: dict) -> None:
    assert proc.stdin is not None
    proc.stdin.write(json.dumps(payload) + "\n")
    proc.stdin.flush()


def main() -> int:
    cli = resolve_cmux_cli()
    if cli is None:
        print("SKIP: cmux CLI binary not built")
        return 0

    env = os.environ.copy()
    home = tempfile.mkdtemp(prefix="blueprint-smoke-home-")
    env["HOME"] = home
    # Outside a cmux terminal and without any socket: the server must still
    # answer discovery and turn tool calls into soft errors.
    for key in ("CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID", "CMUX_SOCKET", "CMUX_SOCKET_PASSWORD", "CMUX_SOCKET_CAPABILITY"):
        env.pop(key, None)
    env["CMUX_SOCKET_PATH"] = str(Path(home) / "missing-cmux.sock")
    proc = subprocess.Popen(
        [str(cli), "blueprint", "mcp"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )
    try:
        send(
            proc,
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-03-26",
                    "capabilities": {},
                    "clientInfo": {"name": "cmux-smoke", "version": "1"},
                },
            },
        )
        init_resp = read_json_line(proc)
        if init_resp.get("error"):
            raise AssertionError(f"initialize returned error: {init_resp}")
        result = init_resp.get("result", {})
        if result.get("serverInfo", {}).get("name") != "cmux-blueprint":
            raise AssertionError(f"unexpected serverInfo: {init_resp}")
        if result.get("protocolVersion") != "2025-03-26":
            raise AssertionError(f"expected the client's supported protocol version to be echoed: {init_resp}")
        if "blueprint_show_mermaid" not in result.get("instructions", ""):
            raise AssertionError(f"initialize should carry agent instructions: {init_resp}")

        send(proc, {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
        send(proc, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        list_resp = read_json_line(proc)
        if list_resp.get("error"):
            raise AssertionError(f"tools/list returned error: {list_resp}")
        tools = list_resp.get("result", {}).get("tools", [])
        names = [tool.get("name") for tool in tools]
        if names != EXPECTED_TOOLS:
            raise AssertionError(f"tool roster changed: {names}")
        for tool in tools:
            schema = tool.get("inputSchema", {})
            if schema.get("type") != "object" or "properties" not in schema:
                raise AssertionError(f"tool {tool.get('name')} lacks an object inputSchema: {tool}")
            if not tool.get("description"):
                raise AssertionError(f"tool {tool.get('name')} lacks a description")

        send(proc, {"jsonrpc": "2.0", "id": 3, "method": "ping", "params": {}})
        ping_resp = read_json_line(proc)
        if ping_resp.get("result") != {}:
            raise AssertionError(f"ping should return an empty result: {ping_resp}")

        send(
            proc,
            {
                "jsonrpc": "2.0",
                "id": 4,
                "method": "tools/call",
                "params": {"name": "blueprint_state", "arguments": {}},
            },
        )
        call_resp = read_json_line(proc)
        call_result = call_resp.get("result", {})
        if call_result.get("isError") is not True:
            raise AssertionError(f"a tool call outside a cmux terminal must be a soft error: {call_resp}")
        text = "".join(part.get("text", "") for part in call_result.get("content", []))
        if "CMUX_SURFACE_ID" not in text:
            raise AssertionError(f"the soft error should explain the missing terminal binding: {call_resp}")

        send(proc, {"jsonrpc": "2.0", "id": 5, "method": "resources/list", "params": {}})
        unknown_resp = read_json_line(proc)
        if unknown_resp.get("error", {}).get("code") != -32601:
            raise AssertionError(f"unknown methods must return -32601: {unknown_resp}")

        if proc.poll() is not None:
            raise AssertionError(f"server exited early with {proc.returncode}")
    finally:
        if proc.stdin is not None:
            proc.stdin.close()
        if proc.poll() is None:
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
        if proc.stderr is not None:
            try:
                proc.stderr.read()
            except Exception:
                pass
        shutil.rmtree(home, ignore_errors=True)

    print(f"PASS: cmux-blueprint MCP smoke ({cli})")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
