"""A small subclass of Pipecat's Ultravox service that keeps the model audible
around client tool calls.

Observed with Pipecat 1.8.1 + Ultravox: the tool result reaches Ultravox only
through an ``LLMContextFrame`` that the assistant aggregator pushes after the
bot "stops speaking". Around a tool call the model emits an empty, final
placeholder turn, and the timing of that bookkeeping leaves the result
undelivered for a while (or, if anything suppresses the placeholder, forever).
Meanwhile Ultravox freezes the conversation until the result arrives, and the
user hears nothing.

Fix: send the ``client_tool_result`` to Ultravox as soon as the handler's
result callback fires, straight from ``run_function_calls``' result path, and
remember the id so the later context-driven send is skipped as a duplicate.
"""

from __future__ import annotations

import json
from typing import Any

from loguru import logger
from pipecat.frames.frames import FunctionCallResultFrame
from pipecat.processors.frame_processor import FrameDirection
from pipecat.services.ultravox.llm import UltravoxRealtimeLLMService


class CmuxUltravoxService(UltravoxRealtimeLLMService):
    async def push_frame(self, frame, direction: FrameDirection = FrameDirection.DOWNSTREAM):  # type: ignore[override]
        # The result callback broadcasts a FunctionCallResultFrame through this
        # service. Deliver it to Ultravox immediately instead of waiting for the
        # aggregator's deferred context push.
        if isinstance(frame, FunctionCallResultFrame):
            await self._deliver_result_now(frame)
        await super().push_frame(frame, direction)

    async def broadcast_frame(self, frame_cls, **kwargs):  # type: ignore[override]
        if frame_cls is FunctionCallResultFrame:
            await self._deliver_result_now(FunctionCallResultFrame(**kwargs))
        await super().broadcast_frame(frame_cls, **kwargs)

    async def _deliver_result_now(self, frame: FunctionCallResultFrame) -> None:
        tool_call_id = frame.tool_call_id
        if not tool_call_id or tool_call_id in self._completed_tool_calls:
            return
        properties = getattr(frame, "properties", None)
        if properties is not None and getattr(properties, "is_final", True) is False:
            return  # intermediate update of an async tool; Ultravox has no channel for it
        if self._function_is_async(frame.function_name):
            return  # async tools take the placeholder + user-text path in the stock service
        result: Any = frame.result
        text = result if isinstance(result, str) else json.dumps(result, ensure_ascii=False, default=str)
        logger.debug(f"{self}: delivering tool result immediately for {frame.function_name}:{tool_call_id}")
        await self._send_tool_result(tool_call_id, text)
        self._completed_tool_calls.add(tool_call_id)
