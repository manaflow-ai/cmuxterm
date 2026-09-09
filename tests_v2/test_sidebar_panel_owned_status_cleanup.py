#!/usr/bin/env python3
"""Exercise public set_status --panel/--pid cleanup through a real app socket.

Set CMUX_SOCKET_PATH to an isolated tagged test app. No installed-app/socket
discovery is used, so running the test cannot target the user's normal app.
"""

from __future__ import annotations

import os
import socket
import subprocess
import sys
import time

from cmux import cmux, cmuxError


def v1(socket_path: str, command: str) -> str:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(10)
        connection.connect(socket_path)
        # v1 metadata replies span multiple lines. A following ping delimits
        # the response without assuming that one recv contains every row.
        connection.sendall((command + "\nping\n").encode())
        with connection.makefile("r") as response:
            lines = []
            while True:
                line = response.readline()
                if not line:
                    raise cmuxError(f"socket closed before completing {command!r}")
                if line.rstrip("\n") == "PONG":
                    break
                lines.append(line.rstrip("\n"))
    result = "\n".join(lines)
    if not lines or any(line.startswith("ERROR") for line in lines):
        raise cmuxError(f"{command!r} failed: {result!r}")
    return result


def wait_statuses(socket_path: str, workspace: str, present: set[str], absent: set[str]) -> str:
    deadline = time.monotonic() + 10
    while True:
        response = v1(socket_path, f"list_status --tab={workspace}")
        if all(key + "=" in response for key in present) and all(
            key + "=" not in response for key in absent
        ):
            return response
        if time.monotonic() >= deadline:
            raise cmuxError(f"expected present={present}, absent={absent}; got {response!r}")
        # set_status is asynchronous telemetry; wait on its observable result.
        time.sleep(0.05)


def main() -> int:
    socket_path = os.environ.get("CMUX_SOCKET_PATH")
    if not socket_path:
        raise cmuxError("CMUX_SOCKET_PATH must name an isolated tagged test app")

    with cmux(socket_path) as client, subprocess.Popen(
        [sys.executable, "-c", "import sys; sys.stdin.buffer.read()"],
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ) as survivor_process:
        workspace = client.new_workspace()
        try:
            surfaces = client.list_surfaces(workspace)
            if not surfaces:
                raise cmuxError("new workspace has no initial surface")
            survivor = surfaces[0][1]
            created = client._call(
                "surface.create", {"workspace_id": workspace, "type": "terminal", "focus": False}
            )
            victim = created["surface_id"]
            closed_keys = {f"pi-error-{victim}", f"pi-turn-{victim}"}
            survivor_key = f"pi-turn-{survivor}"
            unowned_key = "workspace-build"

            for key, value in zip(sorted(closed_keys), ["Pi error", "Pi turn"]):
                v1(socket_path, f"set_status {key} {value} --tab={workspace} --panel={victim} --pid={os.getpid()}")
            v1(socket_path, f"set_status {survivor_key} Pi turn --tab={workspace} --panel={survivor} --pid={survivor_process.pid}")
            v1(socket_path, f"set_status {unowned_key} Building --tab={workspace}")
            wait_statuses(socket_path, workspace, closed_keys | {survivor_key, unowned_key}, set())

            client._call("surface.close", {"workspace_id": workspace, "surface_id": victim})
            remaining_surfaces = {row[1] for row in client.list_surfaces(workspace)}
            if victim in remaining_surfaces or survivor not in remaining_surfaces:
                raise cmuxError(f"teardown closed the wrong surface: {remaining_surfaces}")
            wait_statuses(socket_path, workspace, {survivor_key, unowned_key}, closed_keys)
            if survivor_process.poll() is not None:
                raise cmuxError("surviving status owner exited during teardown")

            # The delayed clear from pi-cmux may still arrive after teardown.
            # It must be harmless and must not clear another surface's entries.
            for key in closed_keys:
                v1(socket_path, f"clear_status {key} --tab={workspace}")
            wait_statuses(socket_path, workspace, {survivor_key, unowned_key}, closed_keys)
            print("PASS: panel-owned Pi error/turn statuses cleared on surface teardown; other statuses preserved")
        finally:
            client.close_workspace(workspace)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
