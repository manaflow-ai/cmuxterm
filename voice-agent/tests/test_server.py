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
    assert res.json()["codeVersion"].isdigit() and res.json()["startedAt"] > 0


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


def test_tls_configuration_points_at_certifi(monkeypatch):
    import bot

    monkeypatch.delenv("SSL_CERT_FILE", raising=False)
    monkeypatch.delenv("REQUESTS_CA_BUNDLE", raising=False)
    bot.configure_tls_certificates()
    assert os.path.isfile(os.environ["SSL_CERT_FILE"])
    assert os.environ["REQUESTS_CA_BUNDLE"] == os.environ["SSL_CERT_FILE"]


def test_tls_configuration_respects_existing_override(monkeypatch):
    import bot

    monkeypatch.setenv("SSL_CERT_FILE", "/custom/ca.pem")
    bot.configure_tls_certificates()
    assert os.environ["SSL_CERT_FILE"] == "/custom/ca.pem"


def test_agent_greets_first_by_default(monkeypatch):
    import bot

    monkeypatch.delenv("CMUX_VOICE_GREETING", raising=False)
    settings = bot.first_speaker_settings('Workspaces (1): 1 "api" (current)\nCurrent workspace "api" has 1 pane(s): pane 1: [terminal "zsh" (focused)]')
    assert "agent" in settings
    assert settings["agent"]["uninterruptible"] is False
    assert 'workspace called "api"' in settings["agent"]["prompt"]


def test_greeting_override_and_off(monkeypatch):
    import bot

    monkeypatch.setenv("CMUX_VOICE_GREETING", "Hi Derek, ready when you are.")
    assert bot.first_speaker_settings()["agent"]["text"] == "Hi Derek, ready when you are."
    monkeypatch.setenv("CMUX_VOICE_GREETING", "off")
    assert bot.first_speaker_settings() == {"user": {}}


def test_greeting_reaches_ultravox_call_request(monkeypatch):
    """The extra `firstSpeakerSettings` must land in the call-creation body."""
    import bot
    from cmux_voice.cmux_client import CmuxClient
    from cmux_voice.policy import ConfirmationPolicy
    from cmux_voice.tools import ALLOWED_METHODS, VoiceTools

    monkeypatch.setenv("ULTRAVOX_API_KEY", "test-key")
    monkeypatch.delenv("CMUX_VOICE_GREETING", raising=False)
    tools = VoiceTools(CmuxClient("/nonexistent.sock", allowed_methods=ALLOWED_METHODS), ConfirmationPolicy())
    llm = bot.build_llm(tools, output_medium="voice", ui_summary="")
    assert llm._params.extra["firstSpeakerSettings"]["agent"]["prompt"].startswith("Greet the user")


def test_prompt_guards_composition_and_git_context():
    from cmux_voice.prompt import build_system_prompt

    prompt = build_system_prompt()
    assert "do not add ideas" in prompt
    assert "not a git repository" in prompt
    assert "go_to_directory" in prompt and "run_shell" in prompt and "compose_and_type" in prompt


def test_prompt_requires_spoken_replies():
    from cmux_voice.prompt import build_system_prompt

    prompt = build_system_prompt()
    assert "Every request gets a spoken reply" in prompt
    assert "ask one short follow-up question" in prompt
    assert "When you get stuck" in prompt


def test_reply_hints_cover_every_outcome():
    import bot

    assert "Ask the user" in bot.with_reply_hint("close_tab", {"ok": True, "status": "needs_confirmation", "say": "Close it?"})["reply"]
    assert "options" in bot.with_reply_hint("go_to_directory", {"ok": True, "status": "ambiguous", "say": "x"})["reply"]
    assert "did not work" in bot.with_reply_hint("split", {"ok": False, "say": "no"})["reply"]
    assert "Answer the user" in bot.with_reply_hint("which_pane", {"ok": True, "say": "pane 1"})["reply"]
    assert "Confirm out loud" in bot.with_reply_hint("split", {"ok": True, "say": "Split right."})["reply"]
