"""Subscribe to cmux's `events.stream` and surface agent turn completions.

`events.stream` takes over a socket connection and writes one JSON frame per
line. This runs on its own connection (never the RPC client's) in a thread,
reconnects with the last `seq`, and hands completed-turn events to an
async callback on the pipeline's event loop.
"""

from __future__ import annotations

import asyncio
import json
import os
import socket
import threading
import time
from dataclasses import dataclass
from typing import Any, Awaitable, Callable, Dict, Optional

from .cmux_client import CAPABILITY_WIRE_PREFIX, default_socket_path

# Hook names that mean "the agent finished responding to the user's prompt".
# SessionEnd is deliberately absent: it follows Stop within a second and would
# double-speak. SubagentStop is noise for a spoken recap.
COMPLETION_HOOKS = {"Stop", "TurnComplete", "AgentStop"}
IGNORED_HOOKS = {"SubagentStop", "SessionEnd"}


@dataclass
class AgentCompletion:
    seq: int
    source: str  # "claude", "codex", "opencode", ...
    hook: str
    workspace_id: Optional[str]
    surface_id: Optional[str]
    occurred_at: Optional[str]
    payload: Dict[str, Any]

    @classmethod
    def from_frame(cls, frame: Dict[str, Any]) -> Optional["AgentCompletion"]:
        if frame.get("type") != "event" or frame.get("category") != "agent":
            return None
        payload = frame.get("payload") or {}
        hook = str(payload.get("hook_event_name") or frame.get("name", "").rsplit(".", 1)[-1] or "")
        if hook in IGNORED_HOOKS or hook not in COMPLETION_HOOKS:
            return None
        # cmux publishes each hook twice (phase "received", then "completed"),
        # and once more without a surface before the surface-resolved copy.
        # The completed, surface-bound copy is the single event per turn.
        if str(payload.get("phase") or "") != "completed":
            return None
        surface_id = frame.get("surface_id") or payload.get("surface_id")
        if not surface_id:
            return None
        return cls(
            seq=int(frame.get("seq") or 0),
            source=str(frame.get("source") or payload.get("_source") or "agent"),
            hook=hook,
            workspace_id=frame.get("workspace_id") or payload.get("workspace_id"),
            surface_id=surface_id,
            occurred_at=frame.get("occurred_at"),
            payload=payload,
        )


Callback = Callable[[AgentCompletion], Awaitable[None]]


class AgentEventSubscriber:
    """Background thread: events.stream(category=agent) -> callback(AgentCompletion)."""

    def __init__(
        self,
        callback: Callback,
        loop: asyncio.AbstractEventLoop,
        *,
        socket_path: Optional[str] = None,
        capability: Optional[str] = None,
        reconnect_delay_s: float = 2.0,
    ) -> None:
        self._callback = callback
        self._loop = loop
        self.socket_path = socket_path or default_socket_path()
        self.capability = capability if capability is not None else os.environ.get("CMUX_SOCKET_CAPABILITY")
        self.reconnect_delay_s = reconnect_delay_s
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self.last_seq = 0
        self.ignore_through_seq = 0
        self.boot_id: Optional[str] = None

    def start(self) -> None:
        if self._thread is not None:
            return
        self._thread = threading.Thread(target=self._run, name="cmux-agent-events", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    # -- internals ---------------------------------------------------------

    def _request_line(self) -> bytes:
        params: Dict[str, Any] = {"categories": ["agent"], "include_heartbeats": True}
        if self.last_seq:
            # Reconnect: resume after the last event we handled.
            params["after_seq"] = self.last_seq
        else:
            # First connect: cmux replays retained history for after_seq=0, and
            # a recap of a turn that finished before the session began is wrong.
            # Ask for the current tail and drop anything replayed (see handle_line).
            params["after_seq"] = 0
        req = {"id": 1, "method": "events.stream", "params": params}
        line = json.dumps(req, separators=(",", ":"))
        if self.capability:
            line = f"{CAPABILITY_WIRE_PREFIX} {self.capability} {line}"
        return (line + "\n").encode("utf-8")

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                self._stream_once()
            except Exception:  # noqa: BLE001
                pass
            if self._stop.wait(self.reconnect_delay_s):
                return

    def _stream_once(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(5.0)
        try:
            sock.connect(self.socket_path)
            sock.sendall(self._request_line())
            sock.settimeout(60.0)  # heartbeats arrive every ~15s
            buf = b""
            while not self._stop.is_set():
                chunk = sock.recv(65536)
                if not chunk:
                    return
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    if line.strip():
                        self.handle_line(line.decode("utf-8", errors="replace"))
        finally:
            try:
                sock.close()
            except OSError:
                pass

    def handle_line(self, line: str) -> Optional[AgentCompletion]:
        try:
            frame = json.loads(line)
        except json.JSONDecodeError:
            return None
        kind = frame.get("type")
        if kind == "ack":
            boot = frame.get("boot_id")
            if self.boot_id and boot != self.boot_id:
                self.last_seq = 0  # app restarted; sequence space reset
            self.boot_id = boot
            resume = frame.get("resume") or {}
            if not self.last_seq:
                # Live events only: skip everything at or below the latest
                # retained seq at subscription time.
                self.ignore_through_seq = int(resume.get("latest_seq") or 0)
            return None
        if kind != "event":
            return None
        seq = int(frame.get("seq") or 0)
        if seq:
            if seq <= self.ignore_through_seq:
                return None
            self.last_seq = max(self.last_seq, seq)
        completion = AgentCompletion.from_frame(frame)
        if completion is None:
            return None
        asyncio.run_coroutine_threadsafe(self._callback(completion), self._loop)
        return completion
