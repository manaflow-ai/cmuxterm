# cmux voice agent

Voice control for cmux. Ultravox Realtime (speech-to-speech) runs through a
Pipecat pipeline; every tool the model can call is a thin wrapper over the
cmux v2 control socket (see `docs/cli-contract.md`).

Status: **Phase 1**. Runs inside cmux (right-sidebar Voice tab, palette
command, View menu item, `toggleVoiceAgent` shortcut) and standalone with the
Pipecat dev runner's web client. User docs: `docs/voice-agent.md`.

## Layout

| Path | What |
|---|---|
| `bot.py` | Pipecat bot: WebRTC transport → RTVI → `UltravoxRealtimeLLMService` (tools) → transport |
| `server.py` | The sidecar cmux launches: token-scoped FastAPI routes, readiness state file, WebRTC signaling |
| `web/main.ts` → `static/audio.js` | Hidden audio page for the in-app WKWebView (`scripts/build-voice-agent-web.sh`) |
| `harness.py` | Text-mode driver (no audio) for checking phrase → tool routing |
| `cmux_voice/cmux_client.py` | Socket client adapted from `tests_v2/cmux.py`, with allowlist + capability envelope |
| `cmux_voice/state.py` | `system.tree` snapshot → numbered summary; resolves "workspace 2", "the pane on the right" |
| `cmux_voice/tools.py` | The v1 tool catalog and handlers (`VoiceTools`) |
| `cmux_voice/policy.py` | Confirmation gate for close/run tools |
| `cmux_voice/prompt.py` | System prompt and the two greetings (first session / resumed session) |
| `cmux_voice/summary.py`, `cmux_voice/completion_flow.py` | "Terminal X is done" callouts and on-request summaries |
| `cmux_voice/ultravox_service.py` | Ultravox tweaks: immediate tool results, urgent (interrupting) text, tool timeout |
| `tests/` | Fake-socket tests for the tool layer |

## Setup

```bash
cd voice-agent
python3 -m venv .venv
.venv/bin/pip install -e . 2>/dev/null || .venv/bin/pip install "pipecat-ai[ultravox,webrtc,silero,runner]==1.8.1" fastapi uvicorn pytest pytest-asyncio
echo 'ULTRAVOX_API_KEY=...' > .env
```

(`uv sync` works too once `uv` is installed; the `local` PyAudio extra is
deliberately not used.)

## Run the spike

cmux must be running. The client discovers the socket the same way the test
suite does; set `CMUX_SOCKET_PATH` to target a tagged debug build.

```bash
.venv/bin/python bot.py -t webrtc          # then open http://localhost:7860/client
CMUX_VOICE_TRUST_TERMINAL=1 .venv/bin/python bot.py -t webrtc   # run commands without confirmation
```

Things to say: "what do I have open", "go to workspace two", "split right",
"open github dot com in a browser", "go back", "type ls", "run ls", "yes",
"read the screen", "close this tab", "no", "goodbye". Actions come back with a
single "Done."; "open Claude Code and tell it to …" sends the prompt without
an "enter"; when an agent finishes anywhere you hear "Terminal X is done.
Would you like a summary?" and "yes" plays the summary.

Text mode (no microphone, still calls Ultravox):

```bash
.venv/bin/python harness.py "what do I have open" "split right"
```

## Live scenarios

With a tagged cmux running and the key in the environment, `scenario.py`
drives real voice turns and scores each by its effect on the terminal:

```bash
CMUX_TAG=voice CMUX_SOCKET_PATH=/tmp/cmux-debug-voice.sock CMUX_VOICE_TRUST_TERMINAL=1 \
  .venv/bin/python scenario.py            # default: cd, git, open Claude Code, prompt it (auto-sent), quit
SCENARIO='[{"say":"split right","check":"in_claude"}]' .venv/bin/python scenario.py
```

It needs `~/Local-Projects/voice-scratch` (a throwaway git repo) and a
focused terminal at least 60 columns wide.

Ready-made scenarios live in `scenarios/`: `ui_terminal.json` (groups, naming,
switching, lazy folders, git, worktree), `claude_flow.json` (prompting Claude
Code, "yes" for the summary), `elsewhere.json` (agent finishes in another
workspace: callout, then the summary on "yes").
Run one with `SCENARIO="$(cat scenarios/ui_terminal.json)" .venv/bin/python scenario.py`.

## Tests

```bash
.venv/bin/python -m pytest -q
```
