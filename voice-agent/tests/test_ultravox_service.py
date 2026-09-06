from __future__ import annotations

import json

import pytest

from cmux_voice.ultravox_service import CmuxUltravoxService
from pipecat.frames.frames import FunctionCallResultFrame


class _Stub(CmuxUltravoxService):
    """Bypass the real constructor; exercise only the immediate-delivery path."""

    def __init__(self, async_tools=()):
        self._completed_tool_calls = set()
        self._async = set(async_tools)
        self.sent = []
        self._name = "stub"  # FrameProcessor.__str__ reads it for the debug log line

    def _function_is_async(self, name):  # type: ignore[override]
        return name in self._async

    async def _send_tool_result(self, tool_call_id, result):  # type: ignore[override]
        self.sent.append((tool_call_id, result))


async def test_result_is_sent_immediately_once():
    svc = _Stub()
    frame = FunctionCallResultFrame(function_name="split", tool_call_id="t1", arguments={}, result={"ok": True, "say": "Split right."})
    await svc._deliver_result_now(frame)
    await svc._deliver_result_now(frame)  # the aggregator path would re-send; dedupe by id
    assert svc.sent == [("t1", json.dumps({"ok": True, "say": "Split right."}))]
    assert "t1" in svc._completed_tool_calls


async def test_async_tools_and_intermediate_results_are_left_to_stock_path():
    svc = _Stub(async_tools={"slow"})
    await svc._deliver_result_now(FunctionCallResultFrame(function_name="slow", tool_call_id="t2", arguments={}, result="x"))
    assert svc.sent == []
