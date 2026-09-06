"""Turn agent completions into speech, with awareness of where the user is.

- Finished in the focused terminal: speak the recap now.
- Finished elsewhere: speak one notice naming the workspace and tab, remember
  it, and speak the recap the moment the user switches to that surface (by
  voice or by clicking). Focus is tracked from cmux's event stream.
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
        if not self.enabled:
            return
        await self.sync_focus()
        if completion.surface_id and self.focused_surface_id and completion.surface_id != self.focused_surface_id:
            self.summarizer.defer(completion)
            logger.info(f"agent finished elsewhere: {completion.source} on {completion.surface_id}")
            self.spoken.append("callout")
            await self.speak(await self.summarizer.callout_for(completion))
            return
        await self._recap(completion)

    async def on_ui_event(self, frame: Dict[str, Any]) -> None:
        name = frame.get("name") or ""
        if name in FOCUS_EVENTS:
            sid = frame.get("surface_id") or (frame.get("payload") or {}).get("selected_surface_id")
            if sid:
                self.focused_surface_id = sid
            if frame.get("workspace_id"):
                self.focused_workspace_id = frame.get("workspace_id")
            pending = self.summarizer.take_pending(sid, frame.get("workspace_id"))
            if pending is not None:
                await asyncio.sleep(self.settle_s)  # let the switch render before reading the screen
                await self._recap(pending)
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

    async def _recap(self, completion: AgentCompletion) -> None:
        briefing = await self.summarizer.briefing_for(completion)
        if briefing is None:
            return
        logger.info(f"completion summary: {completion.source} on {completion.surface_id}")
        self.spoken.append("recap")
        await self.speak(briefing)
