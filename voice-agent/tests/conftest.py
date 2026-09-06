"""A fake cmux control socket for tests.

`FakeCmux` accepts newline-delimited JSON v2 requests on a Unix socket, records
every {method, params}, and replies with canned results (or `ok:false`).
"""

from __future__ import annotations

import json
import os
import socket
import sys
import tempfile
import threading
from typing import Any, Callable, Dict, List, Optional

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from cmux_voice.cmux_client import CAPABILITY_WIRE_PREFIX, CmuxClient  # noqa: E402
from cmux_voice.policy import ConfirmationPolicy  # noqa: E402
from cmux_voice.tools import ALLOWED_METHODS, VoiceTools  # noqa: E402

Responder = Callable[[str, Dict[str, Any]], Any]


def sample_tree() -> Dict[str, Any]:
    """Two workspaces; the current one has a left terminal pane and a right pane with terminal + browser."""
    return {
        "windows": [
            {
                "id": "W1",
                "ref": "window:1",
                "key": True,
                "visible": True,
                "workspaces": [
                    {
                        "id": "WS-A",
                        "ref": "workspace:1",
                        "index": 0,
                        "title": "api",
                        "selected": False,
                        "panes": [
                            {
                                "id": "P-A1",
                                "ref": "pane:1",
                                "index": 0,
                                "focused": True,
                                "surfaces": [
                                    {"id": "S-A1", "ref": "surface:1", "type": "terminal", "title": "zsh", "index_in_pane": 0, "selected_in_pane": True, "focused": True}
                                ],
                            }
                        ],
                    },
                    {
                        "id": "WS-B",
                        "ref": "workspace:3",
                        "index": 1,
                        "title": "web frontend",
                        "selected": True,
                        "panes": [
                            {
                                "id": "P-B1",
                                "ref": "pane:3",
                                "index": 0,
                                "focused": True,
                                "surfaces": [
                                    {"id": "S-B1", "ref": "surface:5", "type": "terminal", "title": "vim", "index_in_pane": 0, "selected_in_pane": True, "focused": True}
                                ],
                            },
                            {
                                "id": "P-B2",
                                "ref": "pane:4",
                                "index": 1,
                                "focused": False,
                                "surfaces": [
                                    {"id": "S-B2", "ref": "surface:6", "type": "terminal", "title": "npm run dev", "index_in_pane": 0, "selected_in_pane": True, "focused": False},
                                    {"id": "S-B3", "ref": "surface:7", "type": "browser", "title": "GitHub", "url": "https://github.com", "index_in_pane": 1, "selected_in_pane": False, "focused": False},
                                ],
                            },
                        ],
                    },
                ],
            }
        ]
    }


def sample_panes() -> Dict[str, Any]:
    return {
        "panes": [
            {"id": "P-B1", "ref": "pane:3", "index": 0, "focused": True, "pixel_frame": {"x": 240, "y": 28, "width": 500, "height": 900}},
            {"id": "P-B2", "ref": "pane:4", "index": 1, "focused": False, "pixel_frame": {"x": 745, "y": 28, "width": 420, "height": 900}},
        ]
    }


class FakeCmux:
    def __init__(self, responder: Optional[Responder] = None) -> None:
        self.dir = tempfile.mkdtemp(prefix="cmux-voice-test-")
        self.path = os.path.join(self.dir, "cmux.sock")
        self.requests: List[Dict[str, Any]] = []
        self.raw_lines: List[str] = []
        self.responder = responder or self.default_responder
        self._server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server.bind(self.path)
        self._server.listen(4)
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    # -- canned world -------------------------------------------------------

    def default_responder(self, method: str, params: Dict[str, Any]) -> Any:
        if method == "system.tree":
            return sample_tree()
        if method == "pane.list":
            return sample_panes()
        if method == "workspace.create":
            return {"workspace_id": "WS-NEW"}
        if method in {"surface.split", "surface.create", "browser.open_split"}:
            return {"surface_id": "S-NEW"}
        if method == "surface.read_text":
            return {"text": "line1\nline2\n$ ls\nREADME.md  src\n$ "}
        if method.startswith("debug."):
            raise ValueError("method_not_found")
        return {}

    # -- server loop --------------------------------------------------------

    def _serve(self) -> None:
        self._server.settimeout(0.2)
        while not self._stop.is_set():
            try:
                conn, _ = self._server.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn: socket.socket) -> None:
        buf = b""
        with conn:
            while not self._stop.is_set():
                try:
                    chunk = conn.recv(65536)
                except OSError:
                    return
                if not chunk:
                    return
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    text = line.decode("utf-8")
                    self.raw_lines.append(text)
                    if text.startswith(CAPABILITY_WIRE_PREFIX + " "):
                        _, _, text = text.split(" ", 2)
                    req = json.loads(text)
                    method, params = req["method"], req.get("params") or {}
                    self.requests.append({"method": method, "params": params})
                    try:
                        result = self.responder(method, params)
                        resp = {"id": req["id"], "ok": True, "result": result}
                    except Exception as e:  # noqa: BLE001
                        resp = {"id": req["id"], "ok": False, "error": {"code": "error", "message": str(e)}}
                    conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))

    def methods(self) -> List[str]:
        return [r["method"] for r in self.requests]

    def close(self) -> None:
        self._stop.set()
        try:
            self._server.close()
        except OSError:
            pass
        try:
            os.unlink(self.path)
        except OSError:
            pass


@pytest.fixture
def fake() -> FakeCmux:
    f = FakeCmux()
    yield f
    f.close()


@pytest.fixture
def tools(fake: FakeCmux) -> VoiceTools:
    client = CmuxClient(fake.path, allowed_methods=ALLOWED_METHODS, connect_timeout_s=2.0, call_timeout_s=5.0)
    t = VoiceTools(client, ConfirmationPolicy(ttl_seconds=5.0))
    yield t
    client.close()
