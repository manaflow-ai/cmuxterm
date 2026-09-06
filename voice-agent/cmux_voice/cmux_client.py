"""Minimal client for the cmux v2 control socket.

Adapted from `tests_v2/cmux.py` (stdlib only). Differences:
- thread-safe `call()` plus an async `acall()` for use from Pipecat handlers,
- optional capability envelope (`CMUX_SOCKET_CAPABILITY`) prepended to every line,
- a method allowlist so the voice agent can never issue anything outside its tool set,
- automatic reconnect on a dropped socket.

Protocol: one JSON object per line.
  Request:  {"id": 1, "method": "surface.list", "params": {...}}
  Response: {"id": 1, "ok": true, "result": {...}} | {"id": 1, "ok": false, "error": {...}}
"""

from __future__ import annotations

import asyncio
import errno
import glob
import json
import os
import select
import socket
import threading
import time
from typing import Any, Dict, Iterable, Optional

CAPABILITY_WIRE_PREFIX = "_cmux_capability_v1"

_APP_SUPPORT_DIR = os.path.expanduser("~/Library/Application Support/cmux")
_STABLE_SOCKET_PATH = os.path.join(_APP_SUPPORT_DIR, "cmux.sock")
_LEGACY_STABLE_SOCKET_PATH = "/tmp/cmux.sock"
_LAST_SOCKET_PATH_FILES = [
    os.path.join(_APP_SUPPORT_DIR, "last-socket-path"),
    "/tmp/cmux-last-socket-path",
]


class CmuxError(Exception):
    """Raised for transport failures and `ok: false` responses."""

    def __init__(self, message: str, code: str = "error", data: Any = None) -> None:
        super().__init__(message)
        self.code = code
        self.data = data


def _read_last_socket_path() -> Optional[str]:
    for marker_path in _LAST_SOCKET_PATH_FILES:
        try:
            with open(marker_path, "r", encoding="utf-8") as f:
                path = f.read().strip()
            if path:
                return path
        except OSError:
            continue
    return None


def default_socket_path() -> str:
    """Same discovery order as tests_v2/cmux.py; `CMUX_SOCKET_PATH` wins."""
    override = os.environ.get("CMUX_SOCKET_PATH")
    if override:
        if os.path.exists(override):
            return override
        if override not in {_STABLE_SOCKET_PATH, _LEGACY_STABLE_SOCKET_PATH}:
            return override

    last_socket = _read_last_socket_path()
    if last_socket and os.path.exists(last_socket):
        return last_socket

    candidates = ["/tmp/cmux-debug.sock", _STABLE_SOCKET_PATH, _LEGACY_STABLE_SOCKET_PATH]
    for path in candidates:
        if os.path.exists(path):
            return path

    discovered = glob.glob("/tmp/cmux-debug-*.sock")
    discovered.extend(glob.glob(os.path.join(_APP_SUPPORT_DIR, "cmux*.sock")))
    discovered = [path for path in discovered if os.path.exists(path)]
    if discovered:
        discovered.sort(key=os.path.getmtime, reverse=True)
        return discovered[0]

    return candidates[0]


class CmuxClient:
    def __init__(
        self,
        socket_path: Optional[str] = None,
        *,
        capability: Optional[str] = None,
        allowed_methods: Optional[Iterable[str]] = None,
        connect_timeout_s: float = 10.0,
        call_timeout_s: float = 20.0,
    ) -> None:
        self.socket_path = socket_path or default_socket_path()
        self.capability = capability if capability is not None else os.environ.get("CMUX_SOCKET_CAPABILITY")
        self.allowed_methods = set(allowed_methods) if allowed_methods is not None else None
        self.connect_timeout_s = connect_timeout_s
        self.call_timeout_s = call_timeout_s
        self._socket: Optional[socket.socket] = None
        self._recv_buffer = ""
        self._next_id = 1
        self._lock = threading.Lock()

    # ------------------------------------------------------------ connection

    @property
    def connected(self) -> bool:
        return self._socket is not None

    def connect(self) -> None:
        with self._lock:
            self._connect_locked()

    def _connect_locked(self) -> None:
        if self._socket is not None:
            return
        start = time.time()
        while not os.path.exists(self.socket_path):
            if time.time() - start >= self.connect_timeout_s:
                raise CmuxError(f"Socket not found at {self.socket_path}. Is cmux running?", code="socket_missing")
            time.sleep(0.1)
        while True:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                sock.connect(self.socket_path)
                sock.settimeout(self.call_timeout_s)
                self._socket = sock
                self._recv_buffer = ""
                return
            except OSError as e:
                try:
                    sock.close()
                except Exception:
                    pass
                if e.errno in (errno.ECONNREFUSED, errno.ENOENT) and time.time() - start < self.connect_timeout_s:
                    time.sleep(0.1)
                    continue
                raise CmuxError(f"Failed to connect to {self.socket_path}: {e}", code="connect_failed")

    def close(self) -> None:
        with self._lock:
            self._close_locked()

    def _close_locked(self) -> None:
        if self._socket is not None:
            try:
                self._socket.close()
            finally:
                self._socket = None
                self._recv_buffer = ""

    def __enter__(self) -> "CmuxClient":
        self.connect()
        return self

    def __exit__(self, *exc: Any) -> bool:
        self.close()
        return False

    # -------------------------------------------------------------- protocol

    def _recv_line(self, timeout_s: float) -> str:
        assert self._socket is not None
        if "\n" in self._recv_buffer:
            line, rest = self._recv_buffer.split("\n", 1)
            self._recv_buffer = rest
            return line
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            remaining = max(0.0, deadline - time.time())
            ready, _, _ = select.select([self._socket], [], [], min(0.2, remaining))
            if not ready:
                continue
            chunk = self._socket.recv(65536)
            if not chunk:
                raise CmuxError("Socket closed", code="socket_closed")
            self._recv_buffer += chunk.decode("utf-8", errors="replace")
            if "\n" in self._recv_buffer:
                line, rest = self._recv_buffer.split("\n", 1)
                self._recv_buffer = rest
                return line
        raise CmuxError("Timed out waiting for response", code="timeout")

    def _encode(self, req_id: int, method: str, params: Dict[str, Any]) -> bytes:
        line = json.dumps({"id": req_id, "method": method, "params": params}, separators=(",", ":"))
        if self.capability:
            line = f"{CAPABILITY_WIRE_PREFIX} {self.capability} {line}"
        return (line + "\n").encode("utf-8")

    def call(self, method: str, params: Optional[Dict[str, Any]] = None, timeout_s: Optional[float] = None) -> Any:
        """Blocking RPC. Raises CmuxError on transport failure or `ok: false`."""
        if self.allowed_methods is not None and method not in self.allowed_methods:
            raise CmuxError(f"Method not allowed for the voice agent: {method}", code="method_not_allowed")
        params = params or {}
        timeout = timeout_s or self.call_timeout_s
        with self._lock:
            for attempt in (1, 2):
                try:
                    self._connect_locked()
                    req_id = self._next_id
                    self._next_id += 1
                    assert self._socket is not None
                    self._socket.sendall(self._encode(req_id, method, params))
                    resp_line = self._recv_line(timeout)
                    break
                except CmuxError as e:
                    if e.code in {"socket_closed", "connect_failed"} and attempt == 1:
                        self._close_locked()
                        continue
                    raise
                except OSError as e:
                    self._close_locked()
                    if attempt == 1:
                        continue
                    raise CmuxError(f"Socket error: {e}", code="socket_error")
        try:
            resp = json.loads(resp_line)
        except json.JSONDecodeError as e:
            raise CmuxError(f"Invalid JSON response: {e}: {resp_line[:200]}", code="bad_response")
        if not isinstance(resp, dict):
            raise CmuxError(f"Invalid response type: {type(resp).__name__}", code="bad_response")
        if resp.get("id") != req_id:
            raise CmuxError(f"Mismatched response id: expected {req_id}, got {resp.get('id')}", code="bad_response")
        if resp.get("ok") is True:
            return resp.get("result")
        err = resp.get("error") or {}
        raise CmuxError(str(err.get("message") or "Unknown error"), code=str(err.get("code") or "error"), data=err.get("data"))

    async def acall(self, method: str, params: Optional[Dict[str, Any]] = None, timeout_s: Optional[float] = None) -> Any:
        return await asyncio.to_thread(self.call, method, params, timeout_s)
