"""cmux voice agent bot: Ultravox Realtime through Pipecat, tools over the cmux socket.

Run with the Pipecat development runner (serves a test web client at /client):

    ULTRAVOX_API_KEY=... .venv/bin/python bot.py -t webrtc

Environment:
    ULTRAVOX_API_KEY            required
    ULTRAVOX_VOICE              optional voice UUID
    CMUX_SOCKET_PATH            optional; otherwise discovered like tests_v2/cmux.py
    CMUX_SOCKET_CAPABILITY      optional capability envelope (set by cmux when it spawns us)
    CMUX_VOICE_TRUST_TERMINAL   "1" to run commands without confirmation
    CMUX_VOICE_MAX_MINUTES      session cap (default 30)
    CMUX_VOICE_GREETING         fixed opening line, or "off" to let the user speak first
    CMUX_VOICE_SUMMARIES        "0" to disable spoken recaps when a coding agent finishes a turn
"""

from __future__ import annotations

import asyncio
import datetime
import os
import uuid
from pathlib import Path
from typing import Any, Dict, Optional

from loguru import logger

from cmux_voice.cmux_client import CmuxClient, CmuxError
from cmux_voice.events import AgentCompletion, AgentEventSubscriber
from cmux_voice.summary import CompletionSummarizer
from cmux_voice.policy import ConfirmationPolicy
from cmux_voice.prompt import build_greeting_prompt, build_system_prompt
from cmux_voice.state import UIState
from cmux_voice.tools import ALLOWED_METHODS, ToolSpec, VoiceTools


def configure_tls_certificates() -> None:
    """Point Python's TLS at certifi's CA bundle when the interpreter has none.

    python.org macOS builds do not install root certificates, so aiohttp,
    websockets, and nltk all fail with CERTIFICATE_VERIFY_FAILED. Setting
    SSL_CERT_FILE / REQUESTS_CA_BUNDLE (only if unset) fixes every client.
    """
    try:
        import certifi
    except ImportError:
        return
    bundle = certifi.where()
    for var in ("SSL_CERT_FILE", "REQUESTS_CA_BUNDLE"):
        os.environ.setdefault(var, bundle)


def load_dotenv_if_present() -> None:
    """Tiny .env loader (no python-dotenv dependency): KEY=VALUE lines, no expansion."""
    env_path = Path(__file__).with_name(".env")
    if not env_path.exists():
        return
    for raw in env_path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip().strip('"').strip("'")
        os.environ.setdefault(key, value)


def first_speaker_settings(ui_summary: str = "") -> Dict[str, Any]:
    """The agent greets the user as soon as the call connects.

    `CMUX_VOICE_GREETING` overrides the generated greeting with fixed text
    (set it to "off" to let the user speak first).
    """
    override = os.environ.get("CMUX_VOICE_GREETING", "").strip()
    if override.lower() in {"off", "none", "user"}:
        return {"user": {}}
    if override:
        return {"agent": {"text": override, "uninterruptible": False}}
    return {"agent": {"prompt": build_greeting_prompt(ui_summary), "uninterruptible": False}}


def build_tools(on_state=None, on_end_session=None) -> VoiceTools:
    client = CmuxClient(allowed_methods=ALLOWED_METHODS)
    policy = ConfirmationPolicy(trust_terminal_input=os.environ.get("CMUX_VOICE_TRUST_TERMINAL") == "1")
    return VoiceTools(client, policy, on_state=on_state, on_end_session=on_end_session)


def build_llm(tools: VoiceTools, *, output_medium: Optional[str] = None, ui_summary: str = ""):
    from pipecat.adapters.schemas.function_schema import FunctionSchema
    from pipecat.adapters.schemas.tools_schema import ToolsSchema
    from pipecat.services.llm_service import FunctionCallParams
    from pipecat.services.ultravox.llm import OneShotInputParams, UltravoxRealtimeLLMService

    api_key = os.environ.get("ULTRAVOX_API_KEY")
    if not api_key:
        raise RuntimeError("ULTRAVOX_API_KEY is not set (put it in voice-agent/.env or the environment).")

    specs = tools.specs()
    schemas = [FunctionSchema(name=s.name, description=s.description, properties=s.properties, required=s.required) for s in specs]

    voice = os.environ.get("ULTRAVOX_VOICE")
    minutes = float(os.environ.get("CMUX_VOICE_MAX_MINUTES", "30"))
    llm = UltravoxRealtimeLLMService(
        params=OneShotInputParams(
            api_key=api_key,
            system_prompt=build_system_prompt(trust_terminal_input=tools.policy.trust_terminal_input, ui_summary=ui_summary),
            temperature=0.0,
            voice=uuid.UUID(voice) if voice else None,
            output_medium=output_medium,
            max_duration=datetime.timedelta(minutes=minutes),
            extra={"firstSpeakerSettings": first_speaker_settings(ui_summary)},
        ),
        one_shot_selected_tools=ToolsSchema(standard_tools=schemas),
    )

    def make_handler(spec: ToolSpec):
        async def handler(params: FunctionCallParams) -> None:
            args: Dict[str, Any] = dict(params.arguments or {})
            logger.info(f"tool {spec.name} {args}")
            try:
                result = await spec.handler(**args)
            except TypeError as e:
                result = {"ok": False, "say": f"I got unexpected arguments for {spec.name}: {e}"}
            except CmuxError as e:
                result = {"ok": False, "say": f"cmux reported an error: {e}"}
            except Exception as e:  # noqa: BLE001
                logger.exception(f"tool {spec.name} failed")
                result = {"ok": False, "say": f"Something went wrong running {spec.name}."}
            logger.info(f"tool {spec.name} -> {result.get('say', '')[:120]}")
            await params.result_callback(result)

        return handler

    for spec in specs:
        llm.register_function(spec.name, make_handler(spec), cancel_on_interruption=spec.cancel_on_interruption)
    return llm


async def run_bot(transport) -> None:
    from pipecat.audio.vad.silero import SileroVADAnalyzer  # noqa: F401  (validated below)
    from pipecat.frames.frames import EndFrame, InputTextRawFrame
    from pipecat.pipeline.pipeline import Pipeline
    from pipecat.pipeline.runner import PipelineRunner
    from pipecat.pipeline.task import PipelineParams, PipelineTask
    from pipecat.processors.frameworks.rtvi import RTVIObserver, RTVIProcessor

    rtvi = RTVIProcessor(transport=transport)
    task_holder: Dict[str, PipelineTask] = {}

    async def on_state(state: UIState) -> None:
        try:
            await rtvi.send_server_message({"type": "ui_state", "summary": state.summary()})
        except Exception:  # noqa: BLE001
            pass

    async def on_end_session() -> None:
        task = task_holder.get("task")
        if task is not None:
            # Let the goodbye be spoken, then end.
            async def _end() -> None:
                await asyncio.sleep(2.0)
                await task.queue_frames([EndFrame()])

            asyncio.create_task(_end())

    tools = build_tools(on_state=on_state, on_end_session=on_end_session)

    ui_summary = ""
    try:
        ui_summary = (await tools.refresh()).summary()
        logger.info(f"cmux socket: {tools.client.socket_path}\n{ui_summary}")
    except CmuxError as e:
        logger.warning(f"cmux not reachable yet: {e}")

    llm = build_llm(tools, output_medium="voice", ui_summary=ui_summary)

    # Completion summaries: cmux's event stream tells us when a coding agent
    # finished a turn; we read that terminal and have the model brief the user.
    summaries_enabled = os.environ.get("CMUX_VOICE_SUMMARIES", "1") != "0"
    summarizer = CompletionSummarizer(CmuxClient(allowed_methods=ALLOWED_METHODS), enabled=summaries_enabled)

    async def on_agent_completion(completion: AgentCompletion) -> None:
        briefing = await summarizer.briefing_for(completion)
        if briefing is None:
            return
        task = task_holder.get("task")
        if task is None:
            return
        logger.info(f"completion summary: {completion.source} on {completion.surface_id}")
        try:
            await rtvi.send_server_message({"type": "agent_completed", "source": completion.source, "surface_id": completion.surface_id})
        except Exception:  # noqa: BLE001
            pass
        await task.queue_frames([InputTextRawFrame(text=briefing)])

    pipeline = Pipeline([transport.input(), rtvi, llm, transport.output()])
    task = PipelineTask(
        pipeline,
        params=PipelineParams(audio_in_sample_rate=48000, audio_out_sample_rate=48000, enable_metrics=False),
        observers=[RTVIObserver(rtvi)],
    )
    task_holder["task"] = task

    @rtvi.event_handler("on_client_ready")
    async def on_client_ready(rtvi_proc):
        await rtvi_proc.set_bot_ready()
        if tools.state is not None:
            await on_state(tools.state)

    @transport.event_handler("on_client_connected")
    async def on_client_connected(transport_, client):
        logger.info("voice client connected")

    @transport.event_handler("on_client_disconnected")
    async def on_client_disconnected(transport_, client):
        logger.info("voice client disconnected")
        await task.cancel()

    subscriber: Optional[AgentEventSubscriber] = None
    if summaries_enabled:
        subscriber = AgentEventSubscriber(on_agent_completion, asyncio.get_running_loop(), socket_path=tools.client.socket_path)
        subscriber.start()

    runner = PipelineRunner(handle_sigint=False)
    try:
        await runner.run(task)
    finally:
        if subscriber is not None:
            subscriber.stop()
        summarizer.client.close()
        tools.client.close()


async def bot(runner_args) -> None:
    """Entry point discovered by the Pipecat development runner."""
    from pipecat.audio.vad.silero import SileroVADAnalyzer
    from pipecat.runner.utils import create_transport
    from pipecat.transports.base_transport import TransportParams

    transport_params = {
        "webrtc": lambda: TransportParams(
            audio_in_enabled=True,
            audio_out_enabled=True,
            vad_analyzer=SileroVADAnalyzer(),
        ),
    }
    transport = await create_transport(runner_args, transport_params)
    await run_bot(transport)


if __name__ == "__main__":
    load_dotenv_if_present()
    configure_tls_certificates()
    from pipecat.runner.run import main

    main()
