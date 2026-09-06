from __future__ import annotations

import asyncio
import json
import time

import pytest

from cmux_voice.cmux_client import CmuxClient
from cmux_voice.events import AgentCompletion, AgentEventSubscriber
from cmux_voice.summary import SUMMARY_INSTRUCTIONS, CompletionSummarizer, condense
from tests.conftest import FakeCmux


def _stop_frame(seq=10, hook="Stop", source="claude", surface="S-B1", phase="completed", category="agent"):
    return json.dumps({
        "type": "event", "category": category, "name": f"agent.hook.{hook}", "seq": seq, "source": source,
        "workspace_id": "WS-B", "surface_id": surface, "occurred_at": "2026-09-06T10:00:00Z",
        "payload": {"hook_event_name": hook, "phase": phase, "_source": source},
    })


# ---------------------------------------------------------------- events


def test_completion_parses_stop_and_ignores_subagent_and_other_categories():
    assert AgentCompletion.from_frame(json.loads(_stop_frame())).hook == "Stop"
    assert AgentCompletion.from_frame(json.loads(_stop_frame(hook="SubagentStop"))) is None
    assert AgentCompletion.from_frame(json.loads(_stop_frame(hook="PreToolUse"))) is None
    assert AgentCompletion.from_frame(json.loads(_stop_frame(category="notification"))) is None


def test_completion_fires_once_per_turn():
    """cmux emits Stop as received+completed, with and without a surface, then SessionEnd."""
    assert AgentCompletion.from_frame(json.loads(_stop_frame(phase="received"))) is None
    assert AgentCompletion.from_frame(json.loads(_stop_frame(surface=""))) is None
    assert AgentCompletion.from_frame(json.loads(_stop_frame(hook="SessionEnd"))) is None
    assert AgentCompletion.from_frame(json.loads(_stop_frame())) is not None


async def test_subscriber_dispatches_completion_and_tracks_seq():
    loop = asyncio.get_running_loop()
    got: list[AgentCompletion] = []

    async def cb(c: AgentCompletion) -> None:
        got.append(c)

    sub = AgentEventSubscriber(cb, loop, socket_path="/nonexistent")
    sub.handle_line(json.dumps({"type": "ack", "boot_id": "B1", "replay_count": 0}))
    sub.handle_line(json.dumps({"type": "heartbeat"}))
    assert sub.handle_line(_stop_frame(seq=7)) is not None
    await asyncio.sleep(0.05)
    assert [c.seq for c in got] == [7] and sub.last_seq == 7
    # App restart resets the cursor.
    sub.handle_line(json.dumps({"type": "ack", "boot_id": "B2"}))
    assert sub.last_seq == 0
    assert "after_seq" in sub._request_line().decode()


def test_subscriber_request_carries_capability_envelope():
    sub = AgentEventSubscriber(lambda c: None, asyncio.new_event_loop(), socket_path="/x", capability="CAP")
    line = sub._request_line().decode()
    assert line.startswith("_cmux_capability_v1 CAP {")
    assert '"categories":["agent"]' in line


# --------------------------------------------------------------- condense


def test_condense_strips_ansi_spinners_and_repeats():
    raw = "\x1b[32m✔ Done\x1b[0m\n\n⠋\n│ box │\nline\nline\nline\n─────\n$ "
    out = condense(raw)
    assert out.splitlines() == ["✔ Done", "│ box │", "line", "$"]


def test_condense_keeps_tail_within_limit():
    out = condense("\n".join(f"row {i}" for i in range(2000)), limit=100)
    assert len(out) <= 100 and out.endswith("row 1999")


# -------------------------------------------------------------- summarizer


async def test_briefing_reads_screen_and_frames_instructions(fake: FakeCmux):
    fake.responder = lambda m, p: {"text": "$ claude\n✔ Edited src/login.py\nAdded 3 tests\n$ "} if m == "surface.read_text" else FakeCmux.default_responder(fake, m, p)
    s = CompletionSummarizer(CmuxClient(fake.path))
    c = AgentCompletion.from_frame(json.loads(_stop_frame()))
    text = await s.briefing_for(c)
    assert text.startswith(SUMMARY_INSTRUCTIONS)
    assert "Agent: claude" in text and "Edited src/login.py" in text
    assert {"method": "surface.read_text", "params": {"lines": 120, "surface_id": "S-B1"}} in fake.requests
    assert s.history[-1].seq == 10


async def test_briefing_debounces_rapid_events_per_surface(fake: FakeCmux):
    s = CompletionSummarizer(CmuxClient(fake.path))
    c = AgentCompletion.from_frame(json.loads(_stop_frame()))
    assert await s.briefing_for(c) is not None
    assert await s.briefing_for(c) is None  # within DEBOUNCE_S
    other = AgentCompletion.from_frame(json.loads(_stop_frame(surface="S-B2")))
    assert await s.briefing_for(other) is not None


async def test_briefing_disabled_returns_none(fake: FakeCmux):
    s = CompletionSummarizer(CmuxClient(fake.path), enabled=False)
    assert await s.briefing_for(AgentCompletion.from_frame(json.loads(_stop_frame()))) is None
    assert fake.requests == []


async def test_subscriber_ignores_replayed_history_on_first_connect():
    loop = asyncio.get_running_loop()
    got: list[AgentCompletion] = []

    async def cb(c: AgentCompletion) -> None:
        got.append(c)

    sub = AgentEventSubscriber(cb, loop, socket_path="/x")
    sub.handle_line(json.dumps({"type": "ack", "boot_id": "B1", "replay_count": 2, "resume": {"latest_seq": 20, "next_seq": 21}}))
    assert sub.handle_line(_stop_frame(seq=19)) is None  # replayed
    assert sub.handle_line(_stop_frame(seq=20)) is None  # replayed
    assert sub.handle_line(_stop_frame(seq=21)) is not None  # live
    await asyncio.sleep(0.05)
    assert [c.seq for c in got] == [21]
    # A reconnect resumes after 21 and must not re-apply the ignore window.
    sub.handle_line(json.dumps({"type": "ack", "boot_id": "B1", "resume": {"latest_seq": 40}}))
    assert sub.handle_line(_stop_frame(seq=22)) is not None


async def test_manual_recap_ignores_debounce_and_disabled(fake: FakeCmux):
    fake.responder = lambda m, p: {"text": "$ npm test\n12 passing\n$ "} if m == "surface.read_text" else FakeCmux.default_responder(fake, m, p)
    s = CompletionSummarizer(CmuxClient(fake.path), enabled=False)
    a = await s.briefing_for_surface("S-B2")
    b = await s.briefing_for_surface("S-B2")
    assert a and b and "12 passing" in a and "Requested by the user" in a
    assert {"method": "surface.read_text", "params": {"lines": 120, "surface_id": "S-B2"}} in fake.requests
