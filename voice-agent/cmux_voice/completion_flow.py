"""Turn agent completions into speech.

- Any terminal, focused or not: the moment an agent finishes a turn, one
  sentence is spoken, interrupting the model if it was talking: "Terminal
  <name> is done. Would you like a summary?" The name is the workspace title,
  or "<workspace> <tab>" when the workspace has more than one terminal.
- The summary plays only when the user asks for it (the summarize_agent tool,
  wired in bot.py), never on its own.
- UI events (create/rename/close/focus) refresh the tools' name cache, debounced,
  so switching by name never needs a round trip first.
"""

from __future__ import annotations

import asyncio
from typing import Any, Awaitable, Callable, Dict, Optional

from loguru import logger

from .cmux_client import CmuxError
from .events import AgentCompletion
from .summary import CompletionSummarizer

Speak = Callable[[str], Awaitable[None]]

FOCUS_EVENTS = {"surface.focused", "workspace.selected", "pane.focused"}
STRUCTURE_EVENTS = {
    "workspace.created", "workspace.renamed", "workspace.closed", "workspace.selected", "workspace.moved",
    "surface.created", "surface.closed", "surface.focused", "surface.moved", "surface.selected",
    "pane.created", "pane.closed",
}


class CompletionFlow:
    def __init__(self, tools, summarizer: CompletionSummarizer, speak: Speak, *, enabled: bool = True, settle_s: float = 0.6) -> None:
        self.tools = tools
        self.summarizer = summarizer
        self.speak = speak
        self.enabled = enabled
        self.settle_s = settle_s
        self.focused_surface_id: Optional[str] = None
        self.focused_workspace_id: Optional[str] = None
        self._refresh_task: Optional[asyncio.Task] = None
        self.spoken: list[str] = []  # what kind of thing was spoken, for tests/diagnostics

    async def sync_focus(self) -> None:
        try:
            ident = await self.tools.client.acall("system.identify") or {}
        except CmuxError:
            return
        f = ident.get("focused") or {}
        self.focused_surface_id = f.get("surface_id") or self.focused_surface_id
        self.focused_workspace_id = f.get("workspace_id") or self.focused_workspace_id

    async def on_agent_completion(self, completion: AgentCompletion) -> None:
        if not self.enabled or not self.summarizer.enabled:
            return
        if not self.summarizer.should_announce(completion):
            return
        logger.info(f"agent finished: {completion.source} on {completion.surface_id}")
        self.spoken.append("callout")
        await self.speak(await self.summarizer.callout_for(completion))

    async def summarize(self, target: Optional[str] = None) -> Dict[str, Any]:
        """The summarize_agent tool: the announced terminal the user is asking
        about (newest when unnamed), else the focused terminal."""
        item = self.summarizer.take_by_name(target)
        if item is not None:
            briefing = await self.summarizer.briefing_for_surface(item.completion.surface_id, source=item.completion.source)
            name = item.terminal_name
        else:
            if target and target.strip():
                return {"ok": False, "say": f"No agent has finished in a terminal called {target}."}
            briefing = await self.summarizer.briefing_for_surface(None, source="focused")
            name = "this terminal"
        if briefing is None:
            return {"ok": False, "say": "I couldn't read that terminal."}
        self.spoken.append("recap")
        return {
            "ok": True,
            "say": briefing,
            "terminal": name,
            "reply": "Summarize the terminal text in this result aloud in under 100 words, then suggest one next step as 'Next, you could tell it to ...'. Call no other tool.",
        }

    async def on_ui_event(self, frame: Dict[str, Any]) -> None:
        name = frame.get("name") or ""
        if name in FOCUS_EVENTS:
            sid = frame.get("surface_id") or (frame.get("payload") or {}).get("selected_surface_id")
            if sid:
                self.focused_surface_id = sid
            if frame.get("workspace_id"):
                self.focused_workspace_id = frame.get("workspace_id")
        if name in STRUCTURE_EVENTS:
            self._schedule_refresh()

    def _schedule_refresh(self) -> None:
        if self._refresh_task is not None and not self._refresh_task.done():
            return

        async def _refresh() -> None:
            await asyncio.sleep(0.25)
            try:
                await self.tools.refresh()
            except CmuxError:
                pass

        self._refresh_task = asyncio.create_task(_refresh())
