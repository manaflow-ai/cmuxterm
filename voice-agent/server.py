"""cmux voice agent sidecar: token-scoped HTTP + WebRTC signaling for the in-app client.

Started by cmux (see Sources/AppDelegate+VoiceAgent.swift) with:
    CMUX_VOICE_AGENT_TOKEN        unguessable path prefix; everything but /healthz lives under it
    CMUX_VOICE_AGENT_PORT         0 = pick an ephemeral port (default)
    CMUX_VOICE_AGENT_STATE_FILE   where to write {"port","pid","launchId","protocolVersion"} once listening
    CMUX_VOICE_AGENT_LAUNCH_ID    echoed into the state file so the app can match the launch
    CMUX_SOCKET_PATH              the app's live control socket (optional; discovered otherwise)
    CMUX_SOCKET_CAPABILITY        capability envelope for the socket (optional)
    ULTRAVOX_API_KEY              required to start a call
    CMUX_VOICE_TRUST_TERMINAL     "1" to run commands without confirmation

Routes:
    GET  /healthz
    GET  /<token>/audio.html            hidden audio page loaded by the app's WKWebView
    GET  /<token>/static/<file>         bundled JS
    POST /<token>/api/offer             SmallWebRTC offer -> answer (starts the Pipecat bot)
    PATCH /<token>/api/offer            trickle ICE candidates
    GET  /<token>/api/state             {"ready": bool, "apiKeyConfigured": bool}

Can also be run by hand:
    CMUX_VOICE_AGENT_TOKEN=dev .venv/bin/python server.py --port 7862
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import secrets
import socket
import sys
import tempfile
from pathlib import Path
from typing import Any, Optional

from fastapi import BackgroundTasks, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, Response
from loguru import logger

from bot import load_dotenv_if_present, run_bot

PROTOCOL_VERSION = 1
HERE = Path(__file__).resolve().parent
STATIC_DIR = HERE / "static"


def _token() -> str:
    token = os.environ.get("CMUX_VOICE_AGENT_TOKEN", "").strip()
    if not token:
        raise SystemExit("CMUX_VOICE_AGENT_TOKEN is required")
    return token


def _check_token(candidate: str, expected: str) -> None:
    if not secrets.compare_digest(candidate.encode("utf-8"), expected.encode("utf-8")):
        raise HTTPException(status_code=404)


def _write_state_file(path: str, port: int, launch_id: Optional[str]) -> None:
    payload = {"port": port, "pid": os.getpid(), "launchId": launch_id, "protocolVersion": PROTOCOL_VERSION}
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".state-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(payload, f)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def build_app(token: str) -> FastAPI:
    from pipecat.transports.smallwebrtc.request_handler import (
        ConnectionMode,
        IceCandidate,
        SmallWebRTCPatchRequest,
        SmallWebRTCRequest,
        SmallWebRTCRequestHandler,
    )
    from pipecat.audio.vad.silero import SileroVADAnalyzer
    from pipecat.transports.base_transport import TransportParams
    from pipecat.transports.smallwebrtc.transport import SmallWebRTCTransport

    app = FastAPI(title="cmux voice agent", docs_url=None, redoc_url=None, openapi_url=None)
    # One live conversation at a time: a new offer replaces the previous connection.
    handler = SmallWebRTCRequestHandler(connection_mode=ConnectionMode.SINGLE)
    active: dict[str, Any] = {"task": None}

    @app.get("/healthz")
    async def healthz() -> dict[str, Any]:
        return {"ok": True, "protocolVersion": PROTOCOL_VERSION}

    @app.get("/{token_param}/api/state")
    async def state(token_param: str) -> dict[str, Any]:
        _check_token(token_param, token)
        return {
            "ready": (STATIC_DIR / "audio.js").exists(),
            "apiKeyConfigured": bool(os.environ.get("ULTRAVOX_API_KEY")),
            "trustTerminalInput": os.environ.get("CMUX_VOICE_TRUST_TERMINAL") == "1",
        }

    @app.get("/{token_param}/audio.html")
    async def audio_page(token_param: str) -> Response:
        _check_token(token_param, token)
        page = STATIC_DIR / "audio.html"
        if not page.exists():
            return Response(
                "voice-agent web bundle missing: run scripts/build-voice-agent-web.sh",
                status_code=503,
                media_type="text/plain",
            )
        return FileResponse(page, media_type="text/html", headers={"Cache-Control": "no-store"})

    @app.get("/{token_param}/static/{name}")
    async def static_file(token_param: str, name: str) -> Response:
        _check_token(token_param, token)
        if "/" in name or name.startswith("."):
            raise HTTPException(status_code=404)
        path = STATIC_DIR / name
        if not path.is_file():
            raise HTTPException(status_code=404)
        return FileResponse(path, headers={"Cache-Control": "no-store"})

    @app.post("/{token_param}/api/offer")
    async def offer(token_param: str, request: Request, background_tasks: BackgroundTasks) -> Any:
        _check_token(token_param, token)
        if not os.environ.get("ULTRAVOX_API_KEY"):
            return JSONResponse({"error": "missing_api_key", "message": "Ultravox API key is not configured."}, status_code=503)
        body = await request.json()
        webrtc_request = SmallWebRTCRequest.from_dict(
            {k: body.get(k) for k in ("sdp", "type", "pc_id", "restart_pc", "request_data", "requestData") if k in body}
        )

        async def on_connection(connection) -> None:
            transport = SmallWebRTCTransport(
                webrtc_connection=connection,
                params=TransportParams(audio_in_enabled=True, audio_out_enabled=True, vad_analyzer=SileroVADAnalyzer()),
            )
            previous = active.get("task")
            if previous is not None and not previous.done():
                previous.cancel()
            active["task"] = asyncio.create_task(_run_bot_logged(transport))

        return await handler.handle_web_request(request=webrtc_request, webrtc_connection_callback=on_connection)

    @app.patch("/{token_param}/api/offer")
    async def ice_candidate(token_param: str, request: Request) -> dict[str, str]:
        _check_token(token_param, token)
        body = await request.json()
        patch = SmallWebRTCPatchRequest(
            pc_id=body["pc_id"],
            candidates=[IceCandidate(**c) for c in body.get("candidates", [])],
        )
        await handler.handle_patch_request(patch)
        return {"status": "success"}

    return app


async def _run_bot_logged(transport) -> None:
    try:
        await run_bot(transport)
    except asyncio.CancelledError:
        raise
    except Exception:  # noqa: BLE001
        logger.exception("voice bot crashed")


def main() -> None:
    load_dotenv_if_present()
    parser = argparse.ArgumentParser(description="cmux voice agent sidecar")
    parser.add_argument("--port", type=int, default=int(os.environ.get("CMUX_VOICE_AGENT_PORT", "0") or 0))
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    logger.remove()
    logger.add(sys.stderr, level="DEBUG" if args.verbose else "INFO")

    token = _token()
    app = build_app(token)

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((args.host, args.port))
    sock.listen(16)
    port = sock.getsockname()[1]

    state_file = os.environ.get("CMUX_VOICE_AGENT_STATE_FILE")
    if state_file:
        _write_state_file(state_file, port, os.environ.get("CMUX_VOICE_AGENT_LAUNCH_ID"))
    logger.info(f"cmux voice agent listening on http://{args.host}:{port}/{token[:6]}…/ (pid {os.getpid()})")

    import uvicorn

    config = uvicorn.Config(app, log_level="warning", access_log=False)
    server = uvicorn.Server(config)
    try:
        asyncio.run(server.serve(sockets=[sock]))
    finally:
        if state_file:
            try:
                os.unlink(state_file)
            except OSError:
                pass


if __name__ == "__main__":
    main()
