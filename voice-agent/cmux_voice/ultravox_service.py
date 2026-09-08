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
from dataclasses import dataclass
from typing import Any, Optional

from loguru import logger
from pipecat.frames.frames import FunctionCallResultFrame, InputTextRawFrame
from pipecat.processors.frame_processor import FrameDirection
from pipecat.services.ultravox.llm import UltravoxRealtimeLLMService


@dataclass
class UrgentTextFrame(InputTextRawFrame):
    """Injected text that must interrupt the model if it is speaking.

    Ultravox's ``user_text_message`` takes an ``urgency``: "immediate" cuts the
    current generation off and answers now, "soon" waits for the current turn,
    "later" is folded into the next natural turn. The stock service always
    sends the default ("soon"); a completion callout needs "immediate".
    """

    urgency: str = "immediate"


# Ultravox gives a client tool 2.5 s by default and abandons the call's turn when
# it is exceeded; several of ours legitimately take longer (directory search,
# waiting for Claude Code's input box, reading command output). 40 s is the
# documented maximum.
TOOL_TIMEOUT = "40s"


class CmuxUltravoxService(UltravoxRealtimeLLMService):
    _pending_urgency: Optional[str] = None

    async def _start_one_shot_call(self, params):  # type: ignore[override]
        # Pipecat reports every failure here as "Failed to connect to Ultravox",
        # hiding the real cause (TLS, a bad key, or a billing limit). Re-raise
        # with the underlying message so the user hears what is wrong.
        try:
            return await super()._start_one_shot_call(params)
        except Exception as e:  # noqa: BLE001
            raise RuntimeError(_describe_call_failure(e)) from e

    def _to_selected_tools(self, tool):  # type: ignore[override]
        selected = super()._to_selected_tools(tool)
        for entry in selected:
            temp = entry.get("temporaryTool")
            if isinstance(temp, dict):
                temp["timeout"] = TOOL_TIMEOUT
        return selected

    async def process_frame(self, frame, direction: FrameDirection):  # type: ignore[override]
        # The stock handler sends InputTextRawFrame text with the default
        # urgency. Remember the requested urgency for the duration of this frame
        # so _send_user_text can attach it.
        if isinstance(frame, UrgentTextFrame):
            self._pending_urgency = frame.urgency
            try:
                await super().process_frame(frame, direction)
            finally:
                self._pending_urgency = None
            return
        await super().process_frame(frame, direction)

    async def _send_user_text(self, text: str):  # type: ignore[override]
        if not self._socket:
            return
        message: dict[str, Any] = {"type": "user_text_message", "text": text}
        if self._pending_urgency:
            message["urgency"] = self._pending_urgency
        await self._send(message)

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


def _describe_call_failure(error: Exception) -> str:
    text = str(error)
    if "402" in text or "subscription" in text.lower():
        return "Ultravox refused to start a call: the account's call allowance is used up. Add billing at ultravox.ai to continue."
    if "401" in text or "403" in text:
        return "Ultravox rejected the API key. Check the key in Settings › Beta Features › Voice Agent."
    if "CERTIFICATE_VERIFY_FAILED" in text or "SSL" in text:
        return "Ultravox connection failed on TLS certificates; the sidecar's certifi bundle is missing."
    if "Ultravox API error" in text:
        return text
    return f"Could not start the Ultravox call: {text[:160]}"
