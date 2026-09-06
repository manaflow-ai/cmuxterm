"""Live scenario harness (manual, needs a running tagged cmux + ULTRAVOX_API_KEY).

Drives the voice pipeline (voice medium) with typed utterances,
capture what the agent SAYS (TTS text), which TOOLS ran, and what the TERMINAL
shows afterwards. Each step has a `check` on the terminal/state so we score
outcomes, not transcripts."""
import asyncio, sys, json, os, subprocess, time, re
sys.path.insert(0, ".")
from bot import build_tools, build_llm
from pipecat.frames.frames import EndFrame, InputTextRawFrame, TTSTextFrame
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.runner import PipelineRunner
from pipecat.pipeline.task import PipelineParams, PipelineTask
from pipecat.processors.frame_processor import FrameProcessor
from loguru import logger
logger.remove(); logger.add(sys.stderr, level="WARNING")
C = os.environ.get("CMUX_CLI", os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts", "cmux-debug-cli.sh")); ENV = {**os.environ, "CMUX_TAG": os.environ.get("CMUX_TAG", "voice")}
def rpc(m, p):
    out = subprocess.run([C, "rpc", m, json.dumps(p)], capture_output=True, text=True, env=ENV).stdout
    try: return json.loads(out or "{}")
    except Exception: return {}
def screen(n=14): return (rpc("surface.read_text", {"lines": n}).get("text") or "")
def tail(n=6): return " ⏎ ".join(l.strip()[:80] for l in screen(n).rstrip().splitlines()[-n:] if l.strip())
def at_shell(): return screen(2).rstrip().endswith("%")
def in_claude(): return any(m in screen(10) for m in ("shift+tab to cycle", "? for shortcuts", "❯"))
def box(): 
    ls = [l for l in screen(10).splitlines() if "❯" in l]; return ls[-1].strip() if ls else ""
def exit_claude():
    for _ in range(3):
        if at_shell(): return True
        rpc("surface.send_key", {"key": "ctrl-u"}); time.sleep(0.3); rpc("surface.send_text", {"text": "/exit"}); time.sleep(0.8); rpc("surface.send_key", {"key": "enter"}); time.sleep(5)
    return at_shell()
def cwd():
    tty = None
    for w in rpc("system.tree", {}).get("windows", [{}])[0].get("workspaces", []):
        if w.get("selected"):
            for p in w["panes"]:
                for s in p["surfaces"]:
                    if s.get("focused"): tty = s.get("tty")
    if not tty: return None
    pids = subprocess.run(["ps", "-t", tty, "-o", "pid="], capture_output=True, text=True).stdout.split()
    for pid in reversed(pids):
        for l in subprocess.run(["lsof", "-a", "-p", pid, "-d", "cwd", "-Fn"], capture_output=True, text=True).stdout.splitlines():
            if l.startswith("n/"): return l[1:]
    return None

DEFAULT_SCENARIO = [
    {"say": "go to the voice scratch folder", "check": "cwd_endswith", "value": "voice-scratch", "wait": 12},
    {"say": "what branch am I on", "check": "at_shell", "wait": 10},
    {"say": "switch me to the develop branch", "check": "screen_contains", "value": "Switched to branch", "wait": 12},
    {"say": "list the files here", "check": "screen_contains", "value": "README.md", "wait": 12},
    {"say": "open claude code", "check": "in_claude", "wait": 18},
    {"say": "tell it to read the readme file and say in one line what this project is", "check": "box_contains", "value": "readme", "wait": 12},
    {"say": "enter", "check": "in_claude", "wait": 45},
    {"say": "quit claude code", "check": "at_shell", "wait": 16},
]
def _tree():
    return rpc("system.tree", {}).get("windows", [{}])[0].get("workspaces", [])
def current_workspace():
    for w in _tree():
        if w.get("selected"): return w.get("title")
def workspace_titles(): return [w.get("title") or "" for w in _tree()]
def focused_tab_title():
    for w in _tree():
        if w.get("selected"):
            for p in w["panes"]:
                for s in p["surfaces"]:
                    if s.get("focused"): return s.get("title")
def tab_titles():
    return [s.get("title") or "" for w in _tree() if w.get("selected") for p in w["panes"] for s in p["surfaces"]]
def group_names(): return [g.get("name") or "" for g in rpc("workspace.group.list", {}).get("groups", [])]
def git_branch(path):
    if not path: return None
    return subprocess.run(["git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD"], capture_output=True, text=True).stdout.strip() or None

SCENARIO = json.loads(os.environ["SCENARIO"]) if os.environ.get("SCENARIO") else DEFAULT_SCENARIO
async def main():
    tools = build_tools(); ui = (await tools.refresh()).summary()
    llm = build_llm(tools, output_medium="voice", ui_summary=ui)
    said = {"cur": "greeting"}; words = {}; calls = {}
    class Tap(FrameProcessor):
        async def process_frame(self, frame, direction):
            await super().process_frame(frame, direction)
            if isinstance(frame, TTSTextFrame): words[said["cur"]] = words.get(said["cur"], "") + frame.text
            await self.push_frame(frame, direction)
    import bot as botmod
    orig = botmod.with_reply_hint
    def spy(name, result):
        calls.setdefault(said["cur"], []).append((name, result.get("say", "")[:90]))
        return orig(name, result)
    botmod.with_reply_hint = spy
    task = PipelineTask(Pipeline([llm, Tap()]), params=PipelineParams(audio_out_sample_rate=48000, enable_metrics=False))
    results = []
    # Same completion wiring as run_bot: recaps, cross-workspace callouts, name cache.
    from cmux_voice.cmux_client import CmuxClient
    from cmux_voice.completion_flow import CompletionFlow
    from cmux_voice.events import AgentEventSubscriber
    from cmux_voice.summary import CompletionSummarizer
    from cmux_voice.tools import ALLOWED_METHODS
    async def speak(text):
        kind = "CALLOUT" if text.startswith("[Agent finished elsewhere") else "RECAP"
        print(f"  >> {kind} injected", flush=True)
        await task.queue_frames([InputTextRawFrame(text=text)])
    flow = CompletionFlow(tools, CompletionSummarizer(CmuxClient(allowed_methods=ALLOWED_METHODS)), speak)
    sub = AgentEventSubscriber(flow.on_agent_completion, asyncio.get_running_loop(), socket_path=tools.client.socket_path, on_ui_event=flow.on_ui_event)
    sub.start(); await flow.sync_focus()
    async def drive():
        await asyncio.sleep(8)
        for i, step in enumerate(SCENARIO):
            key = f"{i+1}"; said["cur"] = key
            await task.queue_frames([InputTextRawFrame(text=step["say"])])
            await asyncio.sleep(step.get("wait", 14))
            check = step.get("check"); ok = None; detail = ""
            if check == "workspace_is":
                cur = current_workspace(); ok = (cur or "").lower() == step["value"].lower(); detail = cur or ""
            elif check == "workspace_exists":
                names = workspace_titles(); ok = any(step["value"].lower() == n.lower() for n in names); detail = ", ".join(names)[:160]
            elif check == "tab_is":
                t = focused_tab_title(); ok = (t or "").lower() == step["value"].lower(); detail = t or ""
            elif check == "tab_exists":
                names = tab_titles(); ok = any(step["value"].lower() == n.lower() for n in names); detail = ", ".join(names)[:160]
            elif check == "group_exists":
                names = group_names(); ok = any(step["value"].lower() == n.lower() for n in names); detail = ", ".join(names)
            elif check == "branch_is":
                b = git_branch(cwd() or ""); ok = b == step["value"]; detail = b or ""
            elif check == "dir_exists":
                ok = os.path.isdir(os.path.expanduser(step["value"])); detail = step["value"]
            elif check == "spoken_contains":
                ok = step["value"].lower() in words.get(key, "").lower(); detail = words.get(key, "")[:120]
            elif check == "at_shell": ok = at_shell()
            elif check == "in_claude": ok = in_claude(); detail = box()
            elif check == "box_contains": ok = step["value"].lower() in box().lower(); detail = box()
            elif check == "cwd_endswith": c = cwd() or ""; ok = c.endswith(step["value"]); detail = c
            elif check == "screen_contains": ok = step["value"] in screen(20); detail = tail(4)
            elif check == "screen_not_contains": ok = step["value"] not in screen(20); detail = tail(4)
            results.append({"say": step["say"], "spoken": words.get(key, "").strip(), "tools": calls.get(key, []), "check": check, "ok": ok, "detail": detail})
        await task.queue_frames([EndFrame()])
    asyncio.create_task(drive())
    await PipelineRunner(handle_sigint=False).run(task)
    sub.stop(); tools.client.close()
    for r in results:
        flag = "PASS" if r["ok"] else ("FAIL" if r["ok"] is False else "----")
        print(f"\n[{flag}] YOU: {r['say']}")
        for n, s in r["tools"]: print(f"       tool {n}: {s}")
        print(f"       SAID: {r['spoken'][:220]!r}")
        if r["detail"]: print(f"       STATE: {r['detail'][:160]}")
asyncio.run(main())
