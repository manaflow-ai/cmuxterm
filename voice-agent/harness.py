"""Text-mode harness: drive the Ultravox tool routing without audio.

Uses a real Ultravox call with text output, so it needs ULTRAVOX_API_KEY and
costs a little. Good for checking that phrasing maps to the right tools.

    .venv/bin/python harness.py "go to workspace two" "split right"
    .venv/bin/python harness.py            # interactive
"""

from __future__ import annotations

import asyncio
import sys

from loguru import logger

from bot import build_llm, build_tools, configure_tls_certificates, load_dotenv_if_present
from cmux_voice.cmux_client import CmuxError


async def run(utterances: list[str]) -> None:
    from pipecat.frames.frames import EndFrame, Frame, InputTextRawFrame, LLMFullResponseEndFrame, LLMTextFrame
    from pipecat.pipeline.pipeline import Pipeline
    from pipecat.pipeline.runner import PipelineRunner
    from pipecat.pipeline.task import PipelineParams, PipelineTask
    from pipecat.processors.frame_processor import FrameDirection, FrameProcessor

    tools = build_tools()
    ui_summary = ""
    try:
        ui_summary = (await tools.refresh()).summary()
        print(ui_summary)
    except CmuxError as e:
        print(f"warning: cmux not reachable: {e}")

    llm = build_llm(tools, output_medium="text", ui_summary=ui_summary)

    turn_done = asyncio.Event()

    class Printer(FrameProcessor):
        def __init__(self) -> None:
            super().__init__()
            self._buf: list[str] = []

        async def process_frame(self, frame: Frame, direction: FrameDirection) -> None:
            await super().process_frame(frame, direction)
            if isinstance(frame, LLMTextFrame):
                self._buf.append(frame.text)
            elif isinstance(frame, LLMFullResponseEndFrame):
                print("agent:", "".join(self._buf).strip())
                self._buf.clear()
                turn_done.set()
            await self.push_frame(frame, direction)

    pipeline = Pipeline([llm, Printer()])
    task = PipelineTask(pipeline, params=PipelineParams(enable_metrics=False))

    async def driver() -> None:
        await asyncio.sleep(2.0)  # let the call connect and the greeting arrive
        turn_done.clear()
        if utterances:
            for text in utterances:
                print("you:", text)
                turn_done.clear()
                await task.queue_frames([InputTextRawFrame(text=text)])
                try:
                    await asyncio.wait_for(turn_done.wait(), timeout=30)
                except asyncio.TimeoutError:
                    print("(no reply within 30s)")
        else:
            loop = asyncio.get_running_loop()
            while True:
                text = await loop.run_in_executor(None, lambda: input("you: "))
                if not text.strip() or text.strip().lower() in {"quit", "exit"}:
                    break
                turn_done.clear()
                await task.queue_frames([InputTextRawFrame(text=text)])
                try:
                    await asyncio.wait_for(turn_done.wait(), timeout=30)
                except asyncio.TimeoutError:
                    print("(no reply within 30s)")
        await task.queue_frames([EndFrame()])

    asyncio.create_task(driver())
    await PipelineRunner(handle_sigint=True).run(task)
    tools.client.close()


if __name__ == "__main__":
    load_dotenv_if_present()
    configure_tls_certificates()
    logger.remove()
    logger.add(sys.stderr, level="WARNING")
    asyncio.run(run(sys.argv[1:]))
