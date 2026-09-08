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
| "Which pane am I in?" | Reads back pane number, position, workspace, and tab |
| "Focus the terminal" / "put the cursor in the terminal" | `surface.focus_input`: focuses the terminal and gives it keyboard focus |
| "Type git status" / "write hello world" | `surface.send_text`, verbatim, no Enter |
| "Start dictating" … "stop dictating" | Everything you say is typed into the terminal until you stop; "send it" presses Enter |
| "Option two" / "the second one" | Down arrow N-1 times then Enter, for Claude Code style choice menus (confirms first unless trusted) |
| "Next" / "previous" / "confirm" / "cancel" | Arrow keys, Enter, Escape in a prompt menu |
| "Scroll up" / "scroll down two pages" / "go to the top" | `surface.scroll` (Ghostty page scroll bindings) |
| "Go to the staff portal folder" / "open the voice agent directory" | Finds the folder by name (current directory first, then Spotlight and project roots), asks if several match, then runs `cd` |
| "Check me out of this branch into develop" / "stage everything and commit saying fix login" | The agent composes the exact git or shell command, reads it back, and runs it after "yes" (destructive commands always confirm) |
| "Where am I?" (in the shell) | Working directory and git branch |
| "Write down: make the login async and add tests" / "tell it to …" / "ask it to …" | Rewrites your rough words into a clear message, types it into the focused input (Claude Code, Codex, or the shell), and sends it. You never have to say "enter" |
| "Open Claude Code" / "start Codex and tell it to add tests for login" | Launches the agent CLI in the terminal, no confirmation; a first prompt is typed and sent in the same breath |
| "Enter" / "send it" | Submits whatever you dictated into the focused input (dictation is the only thing that waits for this) |
| "New group called Clients" / "rename this group to Work" / "switch to group Clients" / "new workspace in Clients called Invoices" | Workspace groups (`workspace.group.*`) |
| "New workspace called API" / "rename this workspace to API" | Created, then named via `workspace.rename` |
| "Split right and call it server" / "call this tab logs" | `surface.rename` (new socket method) |
| "Switch to API" / "go to the logs tab" | Name lookup is cached and refreshed from cmux's event stream, so switching is a single instant call; matching ignores case, dashes, and filler words |
| "Check out develop" / "make a branch called fix-login" / "merge develop" / "commit this as fix login" / "push" / "pull" / "what changed" | `git_action` composes the exact command; confirms unless trusted input is on |
| "Create a worktree for feature-x and open Claude there" | `git worktree add` under `<repo>/.claude/worktrees/`, a new named workspace in it, optionally Claude Code |
| (an agent finishes in any terminal, focused or not) | It interrupts whatever it was saying with "Terminal X is done. Would you like a summary?" Say "yes" for the summary and a suggested next prompt; say nothing to carry on |
| "Yes" / "summarize this terminal" / "what did Claude do" | `summarize_agent`: reads the finished terminal (the newest one, or the one you name) and summarizes it |
| "Goodbye" | Ends the session |

Closing tabs or workspaces always asks first. Running a command asks first
unless **Run Commands Without Confirmation** is on.

## How it talks

It is hands-free and quiet. The first session opens with "Hi there, what
should we build?"; if you turn the microphone off and on again while the chat
log is still on screen it just says "Hey." (the **Clear** button in the Voice
panel makes the next start a first session again).

After that it speaks only when spoken to:

- An action ("split right", "go to the API workspace", "tell it to add tests")
  is done the moment it is recognized, silently, followed by one word: "Done."
  There is no preamble, no readback, and no offer of next steps.
- A question ("what do I have open", "which branch is this", "list the files")
  gets a one- or two-sentence answer from the tool result.
- If you pause mid-sentence it waits a little longer instead of guessing; the
  turn delay is `CMUX_VOICE_TURN_DELAY` seconds (default 0.5) in the sidecar
  environment.
- Only genuinely ambiguous requests get a short question, and confirmation
  questions for closing things or running commands (when trusted input is off)
  are still read aloud and wait for yes or no.

## Agents finishing

When a coding agent (Claude Code, Codex, OpenCode, or any agent with cmux
hooks installed) finishes a turn in any terminal, focused or not, the voice
agent interrupts whatever it was saying with:

> "Terminal *name* is done. Would you like a summary?"

*name* is the workspace title; when that workspace holds more than one
terminal it is the workspace title followed by the tab title ("Terminal Alpha
server is done"). Say "yes" (or name the terminal, if several have finished)
and it reads that terminal and summarizes it in under 100 words: what was
completed, takeaways, warnings, and one suggested next step you could send
back to the agent ("Next, you could tell it to …"). Say nothing, or "no", and
it stays quiet. Set `CMUX_VOICE_SUMMARIES=0` in the sidecar environment to
turn the callouts off.

Each terminal's tab bar also has a **Recap** button (waveform icon, shown
while the voice beta is on). Press it to hear a summary of that terminal on
demand: after a recap you missed, or for any terminal at any time. If no
voice session is live it starts one and speaks the recap once connected.

It listens on cmux's `events.stream` for `agent.hook.Stop` (the surface-bound,
completed copy, once per turn), reads the screen with `surface.read_text`,
strips spinners and repeats, and injects the text into the live call as a
framed briefing the model summarizes aloud. Only the visible screen is read;
no transcript files leave the machine.

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
optional `CMUX_VOICE_GREETING` (fixed opening line that replaces both default
greetings, or `off` to let the user speak first), optional
`CMUX_VOICE_TURN_DELAY` (seconds, default 0.5), `CMUX_VOICE_SUMMARIES=0` to
silence agent-finished callouts.

The audio page tells the sidecar whether the chat log was empty when the
session started (`?session=fresh|resume` on the page URL, passed along in the
WebRTC offer's `request_data`), which picks the greeting.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Panel shows Listening but you hear nothing; a speaker-off icon sits next to the phase | The page's audio element has not started | Click the mic off and on. If it persists, check the Mac's output device; the hidden page plays through the default output |
| "Ultravox refused to start a call: the account's call allowance is used up" | Ultravox 402 | Add billing at ultravox.ai |
| "Ultravox rejected the API key" | Wrong or revoked key | Settings › Beta Features › Voice Agent |
| "This pane is only N columns wide" when asking to split | The pane cannot hold two usable terminals | Say "split down", or "close this pane" first |
| Claude Code opens but ignores the first prompt | Its first-run "trust this folder" dialog | Handled automatically; if it still shows, say "option two" then "confirm" |
| No "Terminal … is done" after a Claude turn | The agent ran outside a cmux terminal, or hooks are off | Run agents inside cmux; Codex/OpenCode need `cmux hooks setup` once |

The sidecar log is at `~/Library/Logs/cmux/voice-agent-<bundle-id>.log`.
Every voice session is one Ultravox call; end the session when you are not
using it to avoid billing for idle minutes.

## Privacy

Audio and transcripts go to Ultravox for the duration of a session. Terminal
text leaves the machine only when you ask the agent to read the screen. The
agent never runs `debug.*` socket methods and never activates the app.
