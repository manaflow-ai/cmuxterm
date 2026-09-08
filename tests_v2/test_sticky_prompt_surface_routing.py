#!/usr/bin/env python3
"""Prompt submission preserves explicit terminal attribution through the socket."""

from __future__ import annotations

import json
import os
import socket
import uuid

from cmux import cmux


def main() -> int:
    socket_path = os.environ["CMUX_SOCKET_PATH"]
    with cmux(socket_path) as client, socket.socket(socket.AF_UNIX) as stream:
        stream.settimeout(10)
        stream.connect(socket_path)
        with stream.makefile("rb") as events:
            stream.sendall((json.dumps({
                "id": "prompts",
                "method": "events.stream",
                "params": {
                    "names": ["workspace.prompt.submitted"],
                    "include_heartbeats": False,
                },
            }) + "\n").encode())
            acknowledgement = json.loads(events.readline())
            assert acknowledgement["type"] == "ack", acknowledgement
            original_workspace = client.current_workspace()
            workspace = client._call("workspace.create", {})["workspace_id"]
            try:
                surfaces = client._call("surface.list", {"workspace_id": workspace})["surfaces"]
                surface = next(row["id"] for row in surfaces if row["type"] == "terminal")
                cases = [(surface, surface), (str(uuid.uuid4()), None), (None, None)]
                for requested_surface, expected_surface in cases:
                    message = f"Sticky prompt routing {uuid.uuid4()}"
                    params = {"workspace_id": workspace, "message": message}
                    if requested_surface is not None:
                        params["surface_id"] = requested_surface
                    outcome = client._call("workspace.prompt_submit", params)
                    assert outcome["message_recorded"], outcome
                    event = json.loads(events.readline())
                    assert event["name"] == "workspace.prompt.submitted", event
                    assert event["workspace_id"] == workspace, event
                    assert event["payload"]["message_preview"] == message, event
                    assert event["surface_id"] == expected_surface, event
                    assert event["payload"]["surface_id"] == expected_surface, event
                    assert client.current_workspace() == original_workspace
            finally:
                client.close_workspace(workspace)
    print("PASS: explicit, unknown, and absent prompt surfaces preserve attribution and focus")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
