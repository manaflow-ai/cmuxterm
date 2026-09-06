from __future__ import annotations

import json
import os

import pytest

pytest.importorskip("httpx")
from fastapi.testclient import TestClient  # noqa: E402

import server  # noqa: E402


@pytest.fixture
def client(monkeypatch, tmp_path):
    monkeypatch.delenv("ULTRAVOX_API_KEY", raising=False)
    app = server.build_app("secret-token")
    return TestClient(app)


def test_healthz_is_public(client):
    res = client.get("/healthz")
    assert res.status_code == 200
    assert res.json()["protocolVersion"] == server.PROTOCOL_VERSION


def test_token_gates_every_other_route(client):
    assert client.get("/wrong/audio.html").status_code == 404
    assert client.get("/wrong/api/state").status_code == 404
    assert client.post("/wrong/api/offer", json={"sdp": "x", "type": "offer"}).status_code == 404
    assert client.get("/secret-token/api/state").status_code == 200


def test_state_reports_missing_api_key(client):
    state = client.get("/secret-token/api/state").json()
    assert state["apiKeyConfigured"] is False


def test_offer_without_api_key_is_503(client):
    res = client.post("/secret-token/api/offer", json={"sdp": "x", "type": "offer"})
    assert res.status_code == 503
    assert res.json()["error"] == "missing_api_key"


def test_static_rejects_path_tricks(client):
    assert client.get("/secret-token/static/../server.py").status_code in (404, 400)
    assert client.get("/secret-token/static/.env").status_code == 404


def test_state_file_is_written_atomically(tmp_path):
    path = tmp_path / "nested" / "state.json"
    server._write_state_file(str(path), 4321, "launch-1")
    data = json.loads(path.read_text())
    assert data == {"port": 4321, "pid": os.getpid(), "launchId": "launch-1", "protocolVersion": 1}
    assert not [p for p in path.parent.iterdir() if p.name.startswith(".state-")]
