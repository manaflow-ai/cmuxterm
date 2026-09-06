# Voice agent (beta)

Talk to cmux to drive workspaces, panes, terminals, and the browser.
Speech goes to [Ultravox Realtime](https://ultravox.ai) (a speech-to-speech
model) through a local [Pipecat](https://pipecat.ai) pipeline; every action the
agent takes is a call to the cmux control socket, so it behaves exactly like the
CLI or the command palette would.

## What it does

| Say | Happens |
|---|---|
| "What do I have open?" | Reads back workspaces, panes, and tabs by number and name |
| "Go to workspace two" / "next workspace" | `workspace.select` / `workspace.next` |
| "Focus the pane on the right" | `pane.focus`, resolved from pane geometry |
| "Split right" / "split down with a browser" | `surface.split` / `browser.open_split` |
| "New workspace called notes" | `workspace.create` |
| "Type ls" | `surface.send_text` (no Enter) |
| "Run ls" → "yes" | `surface.send_text` + `send_key enter` after confirmation |
| "Press control C" | `surface.send_key ctrl-c` |
| "Read the screen" | `surface.read_text` (the text is sent to Ultravox) |
| "Open github dot com" / "go back" / "reload" | `browser.navigate` / `browser.back` / `browser.reload` |
| "Close this tab" → "no" | Nothing (closing always confirms) |
| "Goodbye" | Ends the session |

Closing tabs or workspaces always asks first. Running a command asks first
unless **Run Commands Without Confirmation** is on.

## Setup

1. **Python sidecar** (once per checkout; a bundled runtime is planned):
   ```bash
   cd voice-agent
   python3 -m venv .venv
   .venv/bin/pip install "pipecat-ai[ultravox,webrtc,silero,runner]==1.8.1" fastapi uvicorn
   ../scripts/build-voice-agent-web.sh   # needs node/npm
   ```
2. **Settings › Beta Features › Voice Agent**: turn it on and paste an Ultravox
   API key. The key is stored in a private `0600` file next to the socket
   password (never in `cmux.json`) and only ever reaches the local sidecar's
   environment.
3. Open the right sidebar's **Voice** tab (or run **Toggle Voice Agent** from the
   command palette, the View menu, or bind `toggleVoiceAgent` in Keyboard
   Shortcuts) and click the microphone. macOS asks for microphone access the
   first time.

Release builds need `voiceAgent.startCommand` set to the command that starts
`voice-agent/server.py`; Debug builds find the checkout's `voice-agent/.venv`
automatically.

## How it is wired

```
Voice tab (SwiftUI) ── hidden 1×1 WKWebView ── WebRTC ──► voice-agent/server.py (FastAPI)
      ▲                    (Pipecat JS client)                │  Pipecat pipeline
      └── cmuxVoice bridge: status, transcript, tool events   │  Ultravox Realtime (client tools)
                                                              └──► cmux control socket (v2 JSON)
```

- `Sources/AppDelegate+VoiceAgent.swift` launches the sidecar the way agent chat
  does: unguessable token, ephemeral loopback port, readiness state file, health
  check. The process is terminated when cmux quits.
- `Sources/VoiceAgentAudioWebView.swift` owns the microphone and the call. It
  grants mic capture only to the sidecar's loopback origin.
- `Sources/VoiceAgentSessionState.swift` is the single observable model behind
  the panel, the palette command, the menu item, and the shortcut.
- `voice-agent/cmux_voice/tools.py` is the tool catalog; the socket methods it
  may call are allowlisted in `ALLOWED_METHODS`.
- CLI: `cmux right-sidebar set voice` shows the panel.

## Environment the sidecar receives

`CMUX_VOICE_AGENT_TOKEN`, `CMUX_VOICE_AGENT_PORT=0`, `CMUX_VOICE_AGENT_STATE_FILE`,
`CMUX_VOICE_AGENT_LAUNCH_ID`, `CMUX_SOCKET_PATH`, `CMUX_SOCKET_CAPABILITY`,
`ULTRAVOX_API_KEY`, optional `ULTRAVOX_VOICE`, `CMUX_VOICE_TRUST_TERMINAL=1`,
optional `CMUX_VOICE_GREETING` (fixed opening line, or `off` to let the user speak first).

The agent greets you as soon as the call connects, naming the current
workspace and inviting a command; you can interrupt it at any time.

## Privacy

Audio and transcripts go to Ultravox for the duration of a session. Terminal
text leaves the machine only when you ask the agent to read the screen. The
agent never runs `debug.*` socket methods and never activates the app.
