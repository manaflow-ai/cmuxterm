"""Voice tool registry: framework-agnostic tool definitions over the cmux socket.

Each tool is a `ToolSpec` (name, description, JSON-schema properties, handler).
`bot.py` adapts these to Pipecat `FunctionSchema`s; tests call handlers directly.

Handlers never raise. They return a dict with at least:
  ok:  bool
  say: a short, speakable sentence for the model to relay
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable, Dict, List, Optional

from .cmux_client import CmuxClient, CmuxError
from .policy import ConfirmationPolicy
from .state import Pane, Surface, UIState, Workspace

Handler = Callable[..., Awaitable[Dict[str, Any]]]


@dataclass
class ToolSpec:
    name: str
    description: str
    properties: Dict[str, Any]
    handler: Handler
    required: List[str] = field(default_factory=list)
    # All tools run in milliseconds against the local socket, so they stay
    # synchronous for Ultravox (cancel_on_interruption=True). Marking a tool
    # async would make Ultravox return a placeholder and inject the real result
    # later as user text, which breaks the confirmation flow.
    cancel_on_interruption: bool = True


# Every socket method the voice agent is allowed to send. `CmuxClient` refuses the rest.
ALLOWED_METHODS = frozenset(
    {
        "system.tree",
        "system.identify",
        "pane.list",
        "pane.focus",
        "pane.last",
        "workspace.list",
        "workspace.current",
        "workspace.select",
        "workspace.next",
        "workspace.previous",
        "workspace.last",
        "workspace.create",
        "workspace.rename",
        "workspace.close",
        "workspace.equalize_splits",
        "surface.focus",
        "surface.split",
        "surface.create",
        "surface.close",
        "surface.action",
        "surface.send_text",
        "surface.send_key",
        "surface.read_text",
        "surface.trigger_flash",
        "browser.open_split",
        "browser.navigate",
        "browser.back",
        "browser.forward",
        "browser.reload",
        "browser.url.get",
    }
)

_URL_LIKE = re.compile(r"^(https?://|file://|localhost(:\d+)?(/|$)|[\w.-]+\.[a-z]{2,}(/|:|$))", re.IGNORECASE)


class VoiceTools:
    """Holds the client, the confirmation policy, and a cached UI snapshot."""

    def __init__(
        self,
        client: CmuxClient,
        policy: Optional[ConfirmationPolicy] = None,
        *,
        on_state: Optional[Callable[[UIState], Awaitable[None]]] = None,
        on_end_session: Optional[Callable[[], Awaitable[None]]] = None,
    ) -> None:
        self.client = client
        self.policy = policy or ConfirmationPolicy()
        self.state: Optional[UIState] = None
        self._on_state = on_state
        self._on_end_session = on_end_session

    # ------------------------------------------------------------ snapshot

    async def refresh(self) -> UIState:
        tree = await self.client.acall("system.tree")
        pane_rows: List[Dict[str, Any]] = []
        try:
            pane_rows = list((await self.client.acall("pane.list") or {}).get("panes") or [])
        except CmuxError:
            pane_rows = []
        self.state = UIState.from_tree(tree or {}, pane_rows)
        if self._on_state is not None:
            await self._on_state(self.state)
        return self.state

    async def _state(self) -> UIState:
        return self.state or await self.refresh()

    async def _done(self, say: str, flash_surface: Optional[str] = None, **extra: Any) -> Dict[str, Any]:
        if flash_surface:
            try:
                await self.client.acall("surface.trigger_flash", {"surface_id": flash_surface})
            except CmuxError:
                pass
        try:
            await self.refresh()
        except CmuxError:
            pass
        out = {"ok": True, "say": say}
        out.update(extra)
        return out

    @staticmethod
    def _fail(say: str, **extra: Any) -> Dict[str, Any]:
        out = {"ok": False, "say": say}
        out.update(extra)
        return out

    # ----------------------------------------------------------- resolvers

    async def _workspace(self, target: Optional[str]) -> Workspace | Dict[str, Any]:
        st = await self._state()
        ws = st.resolve_workspace(target)
        if ws is None:
            return self._fail(f"I could not find a workspace called {target}.")
        return ws

    async def _pane(self, target: Optional[str]) -> Pane | Dict[str, Any]:
        st = await self._state()
        pane = st.resolve_pane(target)
        if pane is None:
            return self._fail(f"I could not find a pane matching {target}." if target else "There is no focused pane.")
        return pane

    async def _surface_of_kind(self, target: Optional[str], kind: str, missing: str) -> Surface | Dict[str, Any]:
        st = await self._state()
        if target:
            # Resolve without a kind filter first so a wrong-kind target gets a precise message.
            s = st.resolve_surface(target)
            if s is not None and s.type != kind:
                if s.is_browser or s.is_terminal:
                    return self._fail(f"{s.title or 'That tab'} is a {s.type}, not a {kind}.")
                return self._fail(f"{s.title or 'That tab'} is not a {kind}.")
            if s is None:
                s = st.resolve_surface(target, kind=kind)
            if s is None:
                return self._fail(f"I could not find a {kind} matching {target}.")
            return s
        s = st.resolve_surface(None, kind=kind)
        if s is None:
            return self._fail(missing)
        return s

    async def _terminal(self, target: Optional[str]) -> Surface | Dict[str, Any]:
        return await self._surface_of_kind(target, "terminal", "I could not find a terminal to type into.")

    async def _browser(self, target: Optional[str]) -> Surface | Dict[str, Any]:
        return await self._surface_of_kind(
            target, "browser", "There is no browser open in this workspace. Say open a URL in a split to create one."
        )

    # ----------------------------------------------------------- tools: context

    async def get_ui_state(self) -> Dict[str, Any]:
        try:
            st = await self.refresh()
        except CmuxError as e:
            return self._fail(f"I can't reach cmux: {e}")
        return {"ok": True, "say": st.summary(), "state": st.summary()}

    async def read_terminal(self, target: Optional[str] = None, lines: int = 40) -> Dict[str, Any]:
        s = await self._terminal(target)
        if isinstance(s, dict):
            return s
        try:
            res = await self.client.acall("surface.read_text", {"surface_id": s.id, "lines": int(lines)}) or {}
        except CmuxError as e:
            return self._fail(f"I couldn't read that terminal: {e}")
        text = res.get("text")
        if text is None and res.get("base64"):
            import base64

            text = base64.b64decode(res["base64"]).decode("utf-8", errors="replace")
        text = (text or "").rstrip()
        tail = "\n".join(text.splitlines()[-int(lines):])
        return {"ok": True, "say": tail or "The terminal is empty.", "text": tail, "surface": s.title}

    # ---------------------------------------------------------- tools: navigate

    async def focus_workspace(self, target: str) -> Dict[str, Any]:
        low = (target or "").strip().lower()
        try:
            if low in {"next", "forward"}:
                await self.client.acall("workspace.next")
                return await self._done("Next workspace.")
            if low in {"previous", "prev", "back"}:
                await self.client.acall("workspace.previous")
                return await self._done("Previous workspace.")
            if low in {"last", "recent"}:
                await self.client.acall("workspace.last")
                return await self._done("Back to the last workspace.")
            ws = await self._workspace(target)
            if isinstance(ws, dict):
                return ws
            await self.client.acall("workspace.select", {"workspace_id": ws.id})
            return await self._done(f"Switched to {ws.title}.")
        except CmuxError as e:
            return self._fail(f"I couldn't switch workspace: {e}")

    async def focus_pane(self, target: str) -> Dict[str, Any]:
        low = (target or "").strip().lower()
        try:
            if low in {"last", "previous", "back"}:
                await self.client.acall("pane.last")
                return await self._done("Back to the previous pane.")
            pane = await self._pane(target)
            if isinstance(pane, dict):
                return pane
            await self.client.acall("pane.focus", {"pane_id": pane.id})
            label = pane.selected_surface.title if pane.selected_surface else f"pane {pane.number}"
            return await self._done(f"Focused {label}.")
        except CmuxError as e:
            return self._fail(f"I couldn't focus that pane: {e}")

    async def focus_tab(self, target: str) -> Dict[str, Any]:
        st = await self._state()
        s = st.resolve_surface(target)
        if s is None:
            return self._fail(f"I could not find a tab matching {target}.")
        try:
            await self.client.acall("surface.focus", {"surface_id": s.id})
            return await self._done(f"Focused {s.title or 'that tab'}.")
        except CmuxError as e:
            return self._fail(f"I couldn't focus that tab: {e}")

    # ------------------------------------------------------- tools: create/arrange

    async def create_workspace(self, name: Optional[str] = None, working_directory: Optional[str] = None) -> Dict[str, Any]:
        params: Dict[str, Any] = {"focus": True}
        if name:
            params["title"] = name
        if working_directory:
            params["working_directory"] = working_directory
        try:
            res = await self.client.acall("workspace.create", params) or {}
        except CmuxError as e:
            return self._fail(f"I couldn't create a workspace: {e}")
        return await self._done(f"Created workspace {name}." if name else "Created a new workspace.", workspace_id=res.get("workspace_id"))

    async def rename_workspace(self, title: str, target: Optional[str] = None) -> Dict[str, Any]:
        ws = await self._workspace(target)
        if isinstance(ws, dict):
            return ws
        try:
            await self.client.acall("workspace.rename", {"workspace_id": ws.id, "title": title})
        except CmuxError as e:
            return self._fail(f"I couldn't rename it: {e}")
        return await self._done(f"Renamed to {title}.")

    async def close_workspace(self, target: Optional[str] = None) -> Dict[str, Any]:
        ws = await self._workspace(target)
        if isinstance(ws, dict):
            return ws
        tabs = sum(len(p.surfaces) for p in ws.panes)

        async def execute() -> Dict[str, Any]:
            try:
                await self.client.acall("workspace.close", {"workspace_id": ws.id})
            except CmuxError as e:
                return self._fail(f"I couldn't close it: {e}")
            return await self._done(f"Closed {ws.title}.")

        return self.policy.stage("close_workspace", {"target": target}, f"Close workspace {ws.title} with {tabs} tab{'s' if tabs != 1 else ''}?", execute)

    async def split(self, direction: str = "right", kind: str = "terminal", url: Optional[str] = None) -> Dict[str, Any]:
        d = (direction or "right").strip().lower()
        if d not in {"left", "right", "up", "down"}:
            return self._fail("Direction must be left, right, up, or down.")
        k = (kind or "terminal").strip().lower()
        try:
            if k == "browser" or url:
                params: Dict[str, Any] = {"direction": d}
                if url:
                    params["url"] = _normalize_url(url)
                res = await self.client.acall("browser.open_split", params) or {}
                sid = res.get("surface_id")
                return await self._done(f"Opened a browser {d}.", flash_surface=sid, surface_id=sid)
            res = await self.client.acall("surface.split", {"direction": d, "type": "terminal", "focus": True}) or {}
            sid = res.get("surface_id")
            return await self._done(f"Split {d}.", flash_surface=sid, surface_id=sid)
        except CmuxError as e:
            return self._fail(f"I couldn't split: {e}")

    async def new_tab(self, kind: str = "terminal", url: Optional[str] = None) -> Dict[str, Any]:
        k = (kind or "terminal").strip().lower()
        params: Dict[str, Any] = {"type": "browser" if k == "browser" or url else "terminal"}
        if url:
            params["url"] = _normalize_url(url)
        try:
            res = await self.client.acall("surface.create", params) or {}
        except CmuxError as e:
            return self._fail(f"I couldn't open a new tab: {e}")
        sid = res.get("surface_id")
        return await self._done("Opened a new browser tab." if params["type"] == "browser" else "Opened a new terminal tab.", flash_surface=sid, surface_id=sid)

    async def close_tab(self, target: Optional[str] = None) -> Dict[str, Any]:
        st = await self._state()
        s = st.resolve_surface(target)
        if s is None:
            return self._fail("I could not find that tab.")

        async def execute() -> Dict[str, Any]:
            try:
                await self.client.acall("surface.close", {"surface_id": s.id})
            except CmuxError as e:
                return self._fail(f"I couldn't close it: {e}")
            return await self._done(f"Closed {s.title or 'the tab'}.")

        return self.policy.stage("close_tab", {"target": target}, f"Close the {s.type} tab {s.title}?", execute)

    async def equalize_splits(self) -> Dict[str, Any]:
        try:
            await self.client.acall("workspace.equalize_splits")
        except CmuxError as e:
            return self._fail(f"I couldn't equalize the splits: {e}")
        return await self._done("Splits equalized.")

    # ----------------------------------------------------------- tools: terminal

    async def type_text(self, text: str, target: Optional[str] = None) -> Dict[str, Any]:
        if text is None or text == "":
            return self._fail("There is nothing to type.")
        s = await self._terminal(target)
        if isinstance(s, dict):
            return s
        try:
            await self.client.acall("surface.send_text", {"surface_id": s.id, "text": text})
        except CmuxError as e:
            return self._fail(f"I couldn't type into the terminal: {e}")
        return await self._done(f"Typed {text}.", flash_surface=s.id)

    async def press_key(self, key: str, target: Optional[str] = None) -> Dict[str, Any]:
        k = (key or "").strip().lower().replace(" ", "")
        if not k:
            return self._fail("Which key?")
        aliases = {"control-c": "ctrl-c", "controlc": "ctrl-c", "ctrlc": "ctrl-c", "esc": "escape", "return": "enter", "newline": "enter"}
        k = aliases.get(k, k)
        s = await self._terminal(target)
        if isinstance(s, dict):
            return s

        async def execute() -> Dict[str, Any]:
            try:
                await self.client.acall("surface.send_key", {"surface_id": s.id, "key": k})
            except CmuxError as e:
                return self._fail(f"I couldn't press {k}: {e}")
            return await self._done(f"Pressed {k}.", flash_surface=s.id)

        if k == "enter" and not self.policy.trust_terminal_input:
            return self.policy.stage("press_key", {"key": k, "target": target}, f"Press enter in {s.title or 'the terminal'}?", execute)
        return await execute()

    async def run_command(self, command: str, target: Optional[str] = None) -> Dict[str, Any]:
        if not command or not command.strip():
            return self._fail("What command should I run?")
        s = await self._terminal(target)
        if isinstance(s, dict):
            return s

        async def execute() -> Dict[str, Any]:
            try:
                await self.client.acall("surface.send_text", {"surface_id": s.id, "text": command})
                await self.client.acall("surface.send_key", {"surface_id": s.id, "key": "enter"})
            except CmuxError as e:
                return self._fail(f"I couldn't run that: {e}")
            return await self._done(f"Ran {command}.", flash_surface=s.id)

        if self.policy.trust_terminal_input:
            return await execute()
        return self.policy.stage("run_command", {"command": command, "target": target}, f"Run {command} in {s.title or 'the terminal'}?", execute)

    async def interrupt(self, target: Optional[str] = None) -> Dict[str, Any]:
        s = await self._terminal(target)
        if isinstance(s, dict):
            return s
        try:
            await self.client.acall("surface.send_key", {"surface_id": s.id, "key": "ctrl-c"})
        except CmuxError as e:
            return self._fail(f"I couldn't interrupt: {e}")
        return await self._done("Sent control C.", flash_surface=s.id)

    # ------------------------------------------------------------ tools: browser

    async def browser_navigate(self, url: str, target: Optional[str] = None) -> Dict[str, Any]:
        if not url or not url.strip():
            return self._fail("Which address?")
        st = await self._state()
        s = st.resolve_surface(target, kind="browser")
        try:
            if s is None or not s.is_browser:
                res = await self.client.acall("browser.open_split", {"url": _normalize_url(url), "direction": "right"}) or {}
                sid = res.get("surface_id")
                return await self._done(f"Opened {url} in a new browser.", flash_surface=sid, surface_id=sid)
            await self.client.acall("browser.navigate", {"surface_id": s.id, "url": _normalize_url(url)})
            return await self._done(f"Opened {url}.", flash_surface=s.id, surface_id=s.id)
        except CmuxError as e:
            return self._fail(f"I couldn't open that address: {e}")

    async def browser_history(self, action: str, target: Optional[str] = None) -> Dict[str, Any]:
        a = (action or "").strip().lower()
        method = {"back": "browser.back", "forward": "browser.forward", "reload": "browser.reload", "refresh": "browser.reload"}.get(a)
        if method is None:
            return self._fail("Say back, forward, or reload.")
        s = await self._browser(target)
        if isinstance(s, dict):
            return s
        try:
            await self.client.acall(method, {"surface_id": s.id})
        except CmuxError as e:
            return self._fail(f"I couldn't go {a}: {e}")
        return await self._done({"back": "Went back.", "forward": "Went forward.", "reload": "Reloaded.", "refresh": "Reloaded."}[a], flash_surface=s.id)

    # ------------------------------------------------------------ tools: session

    async def confirm(self, decision: str) -> Dict[str, Any]:
        return await self.policy.decide(decision)

    async def end_session(self) -> Dict[str, Any]:
        if self._on_end_session is not None:
            await self._on_end_session()
        return {"ok": True, "say": "Goodbye.", "status": "ending"}

    # ------------------------------------------------------------- registry

    def specs(self) -> List[ToolSpec]:
        target_prop = {
            "type": "string",
            "description": "Optional. A number from get_ui_state, a name, or words like 'current', 'this'. Omit for the focused one.",
        }
        pane_target_prop = {
            "type": "string",
            "description": "Pane number from get_ui_state, or a direction relative to the focused pane: left, right, up, down. 'last' returns to the previously focused pane.",
        }
        return [
            ToolSpec("get_ui_state", "Get the current workspaces, panes, and tabs with their numbers and names. Call this before acting when unsure.", {}, self.get_ui_state),
            ToolSpec("read_terminal", "Read the last lines of text shown in a terminal.", {"target": target_prop, "lines": {"type": "integer", "description": "How many lines from the bottom. Default 40."}}, self.read_terminal),
            ToolSpec("focus_workspace", "Switch to a workspace by number or name, or 'next', 'previous', 'last'.", {"target": {"type": "string", "description": "Workspace number, name, or next/previous/last."}}, self.focus_workspace, required=["target"]),
            ToolSpec("focus_pane", "Move focus to another pane in the current workspace.", {"target": pane_target_prop}, self.focus_pane, required=["target"]),
            ToolSpec("focus_tab", "Show a tab (surface) by number within the focused pane or by title.", {"target": {"type": "string", "description": "Tab number or title."}}, self.focus_tab, required=["target"]),
            ToolSpec("create_workspace", "Create a new workspace and switch to it.", {"name": {"type": "string", "description": "Optional title."}, "working_directory": {"type": "string", "description": "Optional directory path."}}, self.create_workspace),
            ToolSpec("rename_workspace", "Rename a workspace.", {"title": {"type": "string", "description": "The new name."}, "target": target_prop}, self.rename_workspace, required=["title"]),
            ToolSpec("close_workspace", "Close a workspace. Requires confirmation.", {"target": target_prop}, self.close_workspace),
            ToolSpec("split", "Split the focused pane and open a new terminal or browser there.", {"direction": {"type": "string", "enum": ["left", "right", "up", "down"], "description": "Where the new pane goes. Default right."}, "kind": {"type": "string", "enum": ["terminal", "browser"], "description": "What to open. Default terminal."}, "url": {"type": "string", "description": "For a browser, the address to open."}}, self.split),
            ToolSpec("new_tab", "Open a new tab in the focused pane.", {"kind": {"type": "string", "enum": ["terminal", "browser"], "description": "Default terminal."}, "url": {"type": "string", "description": "For a browser, the address to open."}}, self.new_tab),
            ToolSpec("close_tab", "Close a tab. Requires confirmation.", {"target": target_prop}, self.close_tab),
            ToolSpec("equalize_splits", "Make all panes in the current workspace the same size.", {}, self.equalize_splits),
            ToolSpec("type_text", "Type text into a terminal without pressing enter.", {"text": {"type": "string", "description": "Exactly what to type."}, "target": target_prop}, self.type_text, required=["text"]),
            ToolSpec("press_key", "Press a key in a terminal: enter, escape, tab, up, down, left, right, backspace, ctrl-c, ctrl-d, or combos like ctrl-l.", {"key": {"type": "string", "description": "The key name."}, "target": target_prop}, self.press_key, required=["key"]),
            ToolSpec("run_command", "Type a shell command into a terminal and press enter. Requires confirmation unless trusted input is enabled.", {"command": {"type": "string", "description": "Exactly the command to run."}, "target": target_prop}, self.run_command, required=["command"]),
            ToolSpec("interrupt", "Send control C to a terminal to stop the running program.", {"target": target_prop}, self.interrupt),
            ToolSpec("browser_navigate", "Open a web address in the browser tab, or in a new browser split if there is none.", {"url": {"type": "string", "description": "The address or domain to open."}, "target": target_prop}, self.browser_navigate, required=["url"]),
            ToolSpec("browser_history", "Go back, go forward, or reload in the browser.", {"action": {"type": "string", "enum": ["back", "forward", "reload"]}, "target": target_prop}, self.browser_history, required=["action"]),
            ToolSpec("confirm", "Pass on the user's answer to a pending confirmation question.", {"decision": {"type": "string", "enum": ["yes", "no"], "description": "The user's answer."}}, self.confirm, required=["decision"]),
            ToolSpec("end_session", "End the voice session when the user says stop, goodbye, or that they are done.", {}, self.end_session),
        ]


def _normalize_url(raw: str) -> str:
    u = (raw or "").strip()
    if not u:
        return u
    u = u.replace(" dot ", ".").replace(" slash ", "/")
    if "://" in u:
        return u
    if _URL_LIKE.match(u):
        return "https://" + u
    return "https://www.google.com/search?q=" + u.replace(" ", "+")
