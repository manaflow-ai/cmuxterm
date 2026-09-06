"""Voice tool registry: framework-agnostic tool definitions over the cmux socket.

Each tool is a `ToolSpec` (name, description, JSON-schema properties, handler).
`bot.py` adapts these to Pipecat `FunctionSchema`s; tests call handlers directly.

Handlers never raise. They return a dict with at least:
  ok:  bool
  say: a short, speakable sentence for the model to relay
"""

from __future__ import annotations

import asyncio
import os
import re
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable, Dict, List, Optional

from .cmux_client import CmuxClient, CmuxError
from . import shell_context as shellctx
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
        "surface.scroll",
        "surface.focus_input",
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

_RISKY = re.compile(r"\b(rm\s+-[rf]|git\s+(push\s+.*--force|reset\s+--hard|clean\s+-[fd]|branch\s+-D)|sudo\b|mkfs|dd\s+if=|:\(\)\s*\{)", re.IGNORECASE)


def _is_risky(command: str) -> bool:
    return bool(_RISKY.search(command))


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
        # While on, everything the user says is typed into the terminal verbatim.
        self.dictation_active = False
        self._last_typed_surface: Optional[str] = None

    # ------------------------------------------------------------ snapshot

    async def refresh(self) -> UIState:
        tree = await self.client.acall("system.tree")
        pane_rows: List[Dict[str, Any]] = []
        try:
            pane_rows = list((await self.client.acall("pane.list") or {}).get("panes") or [])
        except CmuxError:
            pane_rows = []
        self.state = UIState.from_tree(tree or {}, pane_rows)
        try:
            rows = (await self.client.acall("workspace.list") or {}).get("workspaces") or []
            dirs = {str(r.get("id")): r.get("current_directory") for r in rows}
            for w in self.state.workspaces:
                w.current_directory = dirs.get(w.id) or w.current_directory
        except CmuxError:
            pass
        if self._on_state is not None:
            await self._on_state(self.state)
        return self.state

    async def _state(self) -> UIState:
        return self.state or await self.refresh()

    async def _state_fresh(self) -> Optional[UIState]:
        try:
            return await self.refresh()
        except CmuxError:
            return None

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
        self._last_typed_surface = s.id
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

    # ------------------------------------------------- tools: focus / where am I

    async def which_pane(self) -> Dict[str, Any]:
        st = await self._state_fresh()
        if st is None:
            return self._fail("I can't reach cmux right now.")
        ws, pane, surface = st.current_workspace, st.focused_pane, st.focused_surface
        if ws is None or pane is None:
            return self._fail("Nothing is focused.")
        where = f" on the {pane.position}" if pane.position else ""
        what = f'{surface.type} "{surface.title}"' if surface else "an empty pane"
        say = f"You are in pane {pane.number} of {len(ws.panes)}{where}, in workspace {ws.title}, on {what}."
        return {"ok": True, "say": say, "pane": pane.number, "workspace": ws.title, "surface": surface.title if surface else None}

    async def focus_terminal(self, target: Optional[str] = None) -> Dict[str, Any]:
        """Put the keyboard cursor in a terminal (the focused one by default)."""
        st = await self._state()
        params: Dict[str, Any] = {}
        if target:
            s = st.resolve_surface(target, kind="terminal")
            if s is None:
                return self._fail(f"I could not find a terminal matching {target}.")
            params["surface_id"] = s.id
        try:
            res = await self.client.acall("surface.focus_input", params) or {}
        except CmuxError as e:
            return self._fail(f"I couldn't focus the terminal: {e}")
        title = ""
        if res.get("surface_id"):
            hit = next((x for p in (st.current_workspace.panes if st.current_workspace else []) for x in p.surfaces if x.id == res["surface_id"]), None)
            title = hit.title if hit else ""
        say = f"Cursor is in {title}." if title else "Cursor is in the terminal."
        if not res.get("input_focused", True):
            say = "Focused the terminal, but the cursor may still be elsewhere. Click into it once."
        return await self._done(say, flash_surface=res.get("surface_id"))

    # ---------------------------------------------------------- tools: dictation

    async def dictate(self, text: str, target: Optional[str] = None) -> Dict[str, Any]:
        """Type the user's words verbatim into the terminal, no Enter."""
        if not text or not text.strip():
            return self._fail("I didn't catch anything to type.")
        s = await self._terminal(target)
        if isinstance(s, dict):
            return s
        try:
            await self.client.acall("surface.send_text", {"surface_id": s.id, "text": text})
        except CmuxError as e:
            return self._fail(f"I couldn't type that: {e}")
        self._last_typed_surface = s.id
        return await self._done("Typed.", flash_surface=s.id, typed=text)

    async def set_dictation(self, enabled: bool) -> Dict[str, Any]:
        self.dictation_active = bool(enabled)
        if self.dictation_active:
            return {"ok": True, "say": "Dictating. Everything you say goes into the terminal. Say stop dictating to finish, or send it to press enter.", "dictation": True}
        return {"ok": True, "say": "Stopped dictating.", "dictation": False}

    # ------------------------------------------------------ tools: menu / options

    async def choose_option(self, number: int, target: Optional[str] = None) -> Dict[str, Any]:
        """Pick item N of a numbered prompt menu (Claude Code style): press Down N-1 times, then Enter."""
        try:
            n = int(number)
        except (TypeError, ValueError):
            return self._fail("Which option number?")
        if n < 1 or n > 20:
            return self._fail("Option numbers go from 1 to 20.")
        s = await self._terminal(target)
        if isinstance(s, dict):
            return s

        async def execute() -> Dict[str, Any]:
            try:
                for _ in range(n - 1):
                    await self.client.acall("surface.send_key", {"surface_id": s.id, "key": "down"})
                await self.client.acall("surface.send_key", {"surface_id": s.id, "key": "enter"})
            except CmuxError as e:
                return self._fail(f"I couldn't choose that: {e}")
            return await self._done(f"Chose option {n}.", flash_surface=s.id)

        # Choosing an option submits it, so it follows the same trust rule as pressing Enter.
        if self.policy.trust_terminal_input:
            return await execute()
        return self.policy.stage("choose_option", {"number": n}, f"Choose option {n}?", execute)

    async def menu_navigate(self, action: str, times: int = 1, target: Optional[str] = None) -> Dict[str, Any]:
        """Move through a prompt menu: next/previous (arrow keys), confirm (Enter), cancel (Escape)."""
        a = (action or "").strip().lower()
        key = {"next": "down", "down": "down", "previous": "up", "prev": "up", "up": "up", "back": "up",
               "confirm": "enter", "select": "enter", "accept": "enter", "cancel": "escape", "escape": "escape",
               "tab": "tab", "space": "space", "toggle": "space"}.get(a)
        if key is None:
            return self._fail("Say next, previous, confirm, or cancel.")
        s = await self._terminal(target)
        if isinstance(s, dict):
            return s
        count = max(1, min(int(times or 1), 20)) if key in {"down", "up", "tab"} else 1

        async def execute() -> Dict[str, Any]:
            try:
                for _ in range(count):
                    await self.client.acall("surface.send_key", {"surface_id": s.id, "key": key})
            except CmuxError as e:
                return self._fail(f"I couldn't press {key}: {e}")
            label = {"down": "Next.", "up": "Previous.", "enter": "Confirmed.", "escape": "Cancelled.", "tab": "Tab.", "space": "Toggled."}[key]
            return await self._done(label, flash_surface=s.id)

        if key == "enter" and not self.policy.trust_terminal_input:
            return self.policy.stage("menu_navigate", {"action": a}, "Press enter to confirm?", execute)
        return await execute()

    # -------------------------------------------------------------- tools: scroll

    async def scroll(self, direction: str = "up", pages: int = 1, target: Optional[str] = None) -> Dict[str, Any]:
        d = (direction or "up").strip().lower()
        d = {"upwards": "up", "downwards": "down", "start": "top", "beginning": "top", "end": "bottom", "latest": "bottom"}.get(d, d)
        if d not in {"up", "down", "top", "bottom"}:
            return self._fail("Say scroll up, down, to the top, or to the bottom.")
        s = await self._terminal(target)
        if isinstance(s, dict):
            return s
        n = max(1, min(int(pages or 1), 50))
        try:
            await self.client.acall("surface.scroll", {"surface_id": s.id, "direction": d, "pages": n})
        except CmuxError as e:
            return self._fail(f"I couldn't scroll: {e}")
        say = {"up": f"Scrolled up {n} page{'s' if n > 1 else ''}.", "down": f"Scrolled down {n} page{'s' if n > 1 else ''}.", "top": "At the top.", "bottom": "At the bottom."}[d]
        return {"ok": True, "say": say}

    # ------------------------------------------------------ tools: shell context

    async def _shell_context(self, surface: Surface) -> shellctx.ShellContext:
        st = await self._state()
        fallback = st.current_workspace.current_directory if st.current_workspace else None
        return await asyncio.to_thread(shellctx.shell_context, surface.tty, fallback)

    async def shell_context(self, target: Optional[str] = None) -> Dict[str, Any]:
        """Where the terminal is: working directory and git branch."""
        s = await self._terminal(target)
        if isinstance(s, dict):
            return s
        ctx = await self._shell_context(s)
        say = f"You are in {shellctx.speakable(ctx.cwd)}" if ctx.cwd else "I can't tell the working directory"
        if ctx.git_branch:
            say += f", on branch {ctx.git_branch}"
        return {"ok": True, "say": say + ".", "cwd": ctx.cwd, "git_branch": ctx.git_branch, "git_root": ctx.git_root}

    async def go_to_directory(self, name: str, parent: Optional[str] = None, target: Optional[str] = None) -> Dict[str, Any]:
        """Find a folder by spoken name and cd into it. Not confirm-gated: navigation is harmless."""
        if not name or not name.strip():
            return self._fail("Which folder?")
        s = await self._terminal(target)
        if isinstance(s, dict):
            return s
        ctx = await self._shell_context(s)
        candidates = await asyncio.to_thread(shellctx.find_directories, name, parent=parent, cwd=ctx.cwd)
        if not candidates:
            return self._fail(f"I couldn't find a folder called {name}." + (f" under {parent}." if parent else ""))
        best = candidates[0]
        others = [c for c in candidates[1:] if os.path.basename(c).lower() == os.path.basename(best).lower()]
        if others and not parent and len(candidates) > 1:
            # Same folder name in several places: ask, listing parents.
            options = ", ".join(shellctx.speakable(c) for c in candidates[:4])
            return {
                "ok": True,
                "status": "ambiguous",
                "say": f"I found several: {options}. Which one?",
                "candidates": candidates[:4],
            }
        command = shellctx.cd_command(best)
        try:
            await self.client.acall("surface.send_text", {"surface_id": s.id, "text": command})
            await self.client.acall("surface.send_key", {"surface_id": s.id, "key": "enter"})
        except CmuxError as e:
            return self._fail(f"I couldn't change directory: {e}")
        return await self._done(f"Now in {shellctx.speakable(best)}.", flash_surface=s.id, path=best, command=command)

    async def run_shell(self, command: str, target: Optional[str] = None) -> Dict[str, Any]:
        """Run a shell command the model composed from the user's intent. Same trust rule as run_command."""
        if not command or not command.strip():
            return self._fail("What should I run?")
        s = await self._terminal(target)
        if isinstance(s, dict):
            return s
        cmd = command.strip()

        async def execute() -> Dict[str, Any]:
            try:
                await self.client.acall("surface.send_text", {"surface_id": s.id, "text": cmd})
                await self.client.acall("surface.send_key", {"surface_id": s.id, "key": "enter"})
            except CmuxError as e:
                return self._fail(f"I couldn't run that: {e}")
            return await self._done(f"Ran {cmd}.", flash_surface=s.id, command=cmd)

        # Trusted input skips the question, except for destructive commands
        # (force pushes, hard resets, rm -rf, sudo), which always confirm.
        if self.policy.trust_terminal_input and not _is_risky(cmd):
            return await execute()
        return self.policy.stage("run_shell", {"command": cmd}, f"Run {cmd}?", execute)

    async def compose_and_type(self, text: str, target: Optional[str] = None) -> Dict[str, Any]:
        """Type a message the model has already rewritten into the focused input (terminal or an agent CLI), no Enter."""
        if not text or not text.strip():
            return self._fail("What should I write?")
        s = await self._terminal(target)
        if isinstance(s, dict):
            return s
        body = text.strip()
        try:
            await self.client.acall("surface.send_text", {"surface_id": s.id, "text": body})
        except CmuxError as e:
            return self._fail(f"I couldn't type that: {e}")
        self._last_typed_surface = s.id
        return await self._done("Written. Say enter to send it.", flash_surface=s.id, typed=body)

    async def press_enter(self, target: Optional[str] = None) -> Dict[str, Any]:
        """Submit whatever is in the focused input. Trust rule: like pressing Enter."""
        s = await self._terminal(target)
        if isinstance(s, dict):
            return s

        async def execute() -> Dict[str, Any]:
            try:
                await self.client.acall("surface.send_key", {"surface_id": s.id, "key": "enter"})
            except CmuxError as e:
                return self._fail(f"I couldn't press enter: {e}")
            self._last_typed_surface = None
            return await self._done("Sent.", flash_surface=s.id)

        if self.policy.trust_terminal_input or self._last_typed_here(s):
            return await execute()
        return self.policy.stage("press_enter", {}, "Press enter?", execute)

    def _last_typed_here(self, s: Surface) -> bool:
        """Enter right after the agent itself typed into this surface needs no confirmation:
        the user already heard what was written."""
        return self._last_typed_surface == s.id

    # -------------------------------------------------------- tools: agents (Claude Code)

    _AGENT_PROMPT_MARKERS = ("❯", ">", "│ >", "Try \"", "auto mode", "shift+tab to cycle", "? for shortcuts", "Type your message")

    async def _wait_for_agent_prompt(self, surface_id: str, timeout_s: float = 12.0) -> bool:
        """Poll the terminal until an agent CLI input box is visible (or time out)."""
        deadline = asyncio.get_running_loop().time() + timeout_s
        while asyncio.get_running_loop().time() < deadline:
            try:
                res = await self.client.acall("surface.read_text", {"surface_id": surface_id, "lines": 12}) or {}
            except CmuxError:
                return False
            text = res.get("text") or ""
            tail = text.rstrip().splitlines()[-6:]
            if any(any(m in line for m in self._AGENT_PROMPT_MARKERS) for line in tail):
                await asyncio.sleep(0.4)  # let the box finish rendering
                return True
            await asyncio.sleep(0.5)
        return False


    async def open_agent(self, agent: str = "claude", prompt: Optional[str] = None, target: Optional[str] = None) -> Dict[str, Any]:
        """Launch a coding agent CLI in the terminal, optionally with a first prompt typed (not sent).

        Launching is harmless, so it never asks. A first prompt is typed only;
        the user says enter to send it, so they can hear it first.
        """
        name = (agent or "claude").strip().lower()
        binary = {"claude": "claude", "claude code": "claude", "codex": "codex", "opencode": "opencode", "gemini": "gemini", "pi": "pi"}.get(name)
        if binary is None:
            return self._fail(f"I don't know how to open {agent}. I can open Claude Code, Codex, OpenCode, Gemini, or Pi.")
        s = await self._terminal(target)
        if isinstance(s, dict):
            return s
        try:
            await self.client.acall("surface.send_text", {"surface_id": s.id, "text": binary})
            await self.client.acall("surface.send_key", {"surface_id": s.id, "key": "enter"})
        except CmuxError as e:
            return self._fail(f"I couldn't open {agent}: {e}")
        label = {"claude": "Claude Code", "codex": "Codex", "opencode": "OpenCode", "gemini": "Gemini", "pi": "Pi"}[binary]
        if prompt and prompt.strip():
            # Type only once the CLI has drawn its input box; typing earlier queues
            # the text as a message behind the launch command. Claude Code can take
            # several seconds to start, so poll the screen instead of sleeping.
            await self._wait_for_agent_prompt(s.id)
            try:
                await self.client.acall("surface.send_text", {"surface_id": s.id, "text": prompt.strip()})
            except CmuxError as e:
                return self._fail(f"Opened {label}, but couldn't type the prompt: {e}")
            self._last_typed_surface = s.id
            return await self._done(f"Opened {label} and typed your prompt. Say enter to send it.", flash_surface=s.id, agent=binary, typed=prompt.strip())
        return await self._done(f"Opened {label}.", flash_surface=s.id, agent=binary)

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
            ToolSpec("which_pane", "Say which pane, workspace, and tab the user is currently in.", {}, self.which_pane),
            ToolSpec("focus_terminal", "Put the keyboard cursor into a terminal so typing goes there. Default: the focused terminal.", {"target": target_prop}, self.focus_terminal),
            ToolSpec("dictate", "Type the user's spoken words into the terminal exactly as said, without pressing enter. Use for 'type ...', 'write ...', or anything said while dictation is on.", {"text": {"type": "string", "description": "The exact words to type. Keep code, paths, and flags literal."}, "target": target_prop}, self.dictate, required=["text"]),
            ToolSpec("set_dictation", "Turn dictation mode on or off. While on, everything the user says is typed into the terminal via dictate, until they say stop dictating.", {"enabled": {"type": "boolean"}}, self.set_dictation, required=["enabled"]),
            ToolSpec("choose_option", "Pick a numbered option from a prompt menu in the terminal, such as a Claude Code choice list: moves down N-1 times and presses enter.", {"number": {"type": "integer", "description": "1-based option number."}, "target": target_prop}, self.choose_option, required=["number"]),
            ToolSpec("menu_navigate", "Move through a prompt menu in the terminal: next or previous (arrow keys), confirm (enter), cancel (escape), tab, or toggle (space).", {"action": {"type": "string", "enum": ["next", "previous", "confirm", "cancel", "tab", "toggle"]}, "times": {"type": "integer", "description": "How many steps for next/previous. Default 1."}, "target": target_prop}, self.menu_navigate, required=["action"]),
            ToolSpec("scroll", "Scroll the terminal view up or down by pages, or jump to the top or bottom.", {"direction": {"type": "string", "enum": ["up", "down", "top", "bottom"]}, "pages": {"type": "integer", "description": "Pages to scroll for up/down. Default 1."}, "target": target_prop}, self.scroll),
            ToolSpec("shell_context", "Report the terminal's working directory and git branch. Call before composing a shell or git command when the answer depends on where the user is.", {"target": target_prop}, self.shell_context),
            ToolSpec("go_to_directory", "Change the terminal's directory to a folder the user names. Finds it by name (relative to the current directory, then by search) and runs cd. Ask only if several folders share the name.", {"name": {"type": "string", "description": "Folder name or path as spoken, e.g. 'staff portal', 'voice agent', 'src/lib'."}, "parent": {"type": "string", "description": "Optional parent folder name to disambiguate."}, "target": target_prop}, self.go_to_directory, required=["name"]),
            ToolSpec("run_shell", "Run a shell or git command that YOU composed from the user's intent, e.g. 'switch to develop' -> git checkout develop. Compose exact, correct syntax; call shell_context first if it depends on the current branch or directory. Requires confirmation unless trusted input is on.", {"command": {"type": "string", "description": "The exact command line."}, "target": target_prop}, self.run_shell, required=["command"]),
            ToolSpec("compose_and_type", "Write a message YOU rewrote from the user's rough words into the focused input, such as a Claude Code prompt or a commit message, without sending it. The user then says enter to send.", {"text": {"type": "string", "description": "The polished text to type."}, "target": target_prop}, self.compose_and_type, required=["text"]),
            ToolSpec("press_enter", "Press enter to submit whatever is in the focused input, terminal or agent CLI. Use when the user says enter, send, submit, or go.", {"target": target_prop}, self.press_enter),
            ToolSpec("open_agent", "Open a coding agent CLI (Claude Code by default; also Codex, OpenCode, Gemini, Pi) in the terminal. Optionally type a first prompt YOU composed from the user's request; it is typed but not sent until the user says enter. Never asks for confirmation.", {"agent": {"type": "string", "description": "claude (default), codex, opencode, gemini, or pi."}, "prompt": {"type": "string", "description": "Optional first prompt, already rewritten into a clear instruction."}, "target": target_prop}, self.open_agent),
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
