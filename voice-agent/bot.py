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
                                (default: "Hi there, what should we build?" for a new chat,
                                "Hey." when the call resumes an existing chat log)
    CMUX_VOICE_SUMMARIES        "0" to disable "Terminal X is done" callouts and summaries
    CMUX_VOICE_TURN_DELAY       seconds Ultravox waits after the user seems done before
                                answering (default 0.5; a small buffer for thinking pauses)
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
from cmux_voice import shell_context
from cmux_voice.completion_flow import CompletionFlow
from cmux_voice.events import AgentCompletion, AgentEventSubscriber
from cmux_voice.summary import CompletionSummarizer
from cmux_voice.policy import ConfirmationPolicy
from cmux_voice.prompt import build_system_prompt, greeting_text
from cmux_voice.state import UIState
from cmux_voice.tools import ALLOWED_METHODS, ToolSpec, VoiceTools
from cmux_voice.ultravox_service import UrgentTextFrame


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


def first_speaker_settings(session: Optional[str] = None) -> Dict[str, Any]:
    """The agent's opening line, spoken as soon as the call connects.

    `session` is "fresh" (the chat log is empty: a new conversation) or
    "resume" (the user toggled the microphone with the log still on screen).
    `CMUX_VOICE_GREETING` overrides both with fixed text (or "off" to let the
    user speak first).
    """
    override = os.environ.get("CMUX_VOICE_GREETING", "").strip()
    if override.lower() in {"off", "none", "user"}:
        return {"user": {}}
    text = override or greeting_text(session)
    return {"agent": {"text": text, "uninterruptible": False}}


def vad_settings() -> Dict[str, str]:
    """Turn-taking: a slightly longer endpoint delay than Ultravox's default
    (0.384 s) so a thinking pause mid-request does not cut the user off, while
    still answering quickly once they stop."""
    delay = float(os.environ.get("CMUX_VOICE_TURN_DELAY", "0.5") or 0.5)
    delay = min(max(delay, 0.2), 3.0)
    return {"turnEndpointDelay": f"{delay:g}s", "minimumInterruptionDuration": "0.2s"}


QUERY_TOOLS = {"get_ui_state", "read_terminal", "which_pane", "shell_context"}


def with_reply_hint(tool_name: str, result: Dict[str, Any]) -> Dict[str, Any]:
    """Attach an instruction for the spoken reply.

    Ultravox sees the tool result as data; the hint states what kind of reply
    this outcome needs. Actions get exactly one word ("Done."); questions get
    an answer; problems get a few words.
    """
    out = dict(result)
    if out.get("reply"):
        return out  # the handler already said what to do (summaries)
    status = out.get("status")
    if status == "needs_confirmation":
        out["reply"] = "Ask the user this question aloud, then wait for their yes or no."
    elif status == "ambiguous":
        out["reply"] = "Read the options aloud briefly and ask which one they meant."
    elif status == "nothing_pending":
        out["reply"] = "Say there was nothing waiting to confirm, in a few words."
    elif out.get("ok") is False:
        out["reply"] = "Say in a few words that this did not work and why. No next steps unless asked."
    elif tool_name in QUERY_TOOLS:
        out["reply"] = "Answer the user's question from this information in one or two short spoken sentences."
    elif tool_name in {"run_shell", "run_command"} and out.get("output"):
        out["reply"] = "If the user asked a question, answer it from the output in one short sentence (read short lists, summarize long output). If they asked for an action, say only: Done."
    else:
        out["reply"] = "Say only the word: Done. Nothing else."
    return out


def build_tools(on_state=None, on_end_session=None, on_summarize=None) -> VoiceTools:
    client = CmuxClient(allowed_methods=ALLOWED_METHODS)
    policy = ConfirmationPolicy(trust_terminal_input=os.environ.get("CMUX_VOICE_TRUST_TERMINAL") == "1")
    return VoiceTools(client, policy, on_state=on_state, on_end_session=on_end_session, on_summarize=on_summarize)


def build_llm(tools: VoiceTools, *, output_medium: Optional[str] = None, ui_summary: str = "", session: Optional[str] = None):
    from pipecat.adapters.schemas.function_schema import FunctionSchema
    from pipecat.adapters.schemas.tools_schema import ToolsSchema
    from pipecat.services.llm_service import FunctionCallParams
    from pipecat.services.ultravox.llm import OneShotInputParams

    from cmux_voice.ultravox_service import CmuxUltravoxService as UltravoxRealtimeLLMService

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
            extra={"firstSpeakerSettings": first_speaker_settings(session), "vadSettings": vad_settings()},
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
            await params.result_callback(with_reply_hint(spec.name, result))

        return handler

    for spec in specs:
        llm.register_function(spec.name, make_handler(spec), cancel_on_interruption=spec.cancel_on_interruption)
    return llm


async def run_bot(transport, *, session: Optional[str] = None) -> None:
    """One voice call. `session` is "fresh" or "resume" (see first_speaker_settings)."""
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

    flow_holder: Dict[str, CompletionFlow] = {}

    async def on_summarize(target: Optional[str]) -> Dict[str, Any]:
        flow = flow_holder.get("flow")
        if flow is None:
            return {"ok": False, "say": "Summaries are turned off for this session."}
        return await flow.summarize(target)

    tools = build_tools(on_state=on_state, on_end_session=on_end_session, on_summarize=on_summarize)
    asyncio.get_running_loop().run_in_executor(None, shell_context.build_directory_index)

    ui_summary = ""
    try:
        ui_summary = (await tools.refresh()).summary()
        logger.info(f"cmux socket: {tools.client.socket_path}\n{ui_summary}")
    except CmuxError as e:
        logger.warning(f"cmux not reachable yet: {e}")

    llm = build_llm(tools, output_medium="voice", ui_summary=ui_summary, session=session)

    # Completion callouts: cmux's event stream tells us when a coding agent
    # finished a turn; the model announces it at once (interrupting itself if
    # it was talking) and summarizes only when the user says yes.
    summaries_enabled = os.environ.get("CMUX_VOICE_SUMMARIES", "1") != "0"
    summarizer = CompletionSummarizer(CmuxClient(allowed_methods=ALLOWED_METHODS), enabled=summaries_enabled)

    async def speak(text: str) -> None:
        task = task_holder.get("task")
        if task is None:
            return
        try:
            await rtvi.send_server_message({"type": "agent_completed"})
        except Exception:  # noqa: BLE001
            pass
        await task.queue_frames([UrgentTextFrame(text=text, urgency="immediate")])

    flow = CompletionFlow(tools, summarizer, speak, enabled=summaries_enabled)
    flow_holder["flow"] = flow
    on_agent_completion = flow.on_agent_completion
    on_ui_event = flow.on_ui_event

    pipeline = Pipeline([transport.input(), rtvi, llm, transport.output()])
    task = PipelineTask(
        pipeline,
        params=PipelineParams(audio_in_sample_rate=48000, audio_out_sample_rate=48000, enable_metrics=False),
        observers=[RTVIObserver(rtvi)],
    )
    task_holder["task"] = task

    @rtvi.event_handler("on_client_message")
    async def on_client_message(rtvi_proc, message):
        # The app's Recap button (per-terminal) asks for a spoken summary of one surface.
        data = getattr(message, "data", None) or {}
        if getattr(message, "type", "") == "recap":
            surface_id = data.get("surface_id") if isinstance(data, dict) else None
            briefing = await summarizer.briefing_for_surface(surface_id, source="manual")
            if briefing is None:
                await rtvi_proc.send_server_response(message, {"ok": False, "error": "Could not read that terminal."})
                return
            await rtvi_proc.send_server_response(message, {"ok": True})
            await task.queue_frames([InputTextRawFrame(text=briefing)])

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
        subscriber = AgentEventSubscriber(on_agent_completion, asyncio.get_running_loop(), socket_path=tools.client.socket_path, on_ui_event=on_ui_event)
        subscriber.start()
        await flow.sync_focus()

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
