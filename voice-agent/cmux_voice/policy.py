"""Confirmation policy for destructive or command-running tools.

The model cannot bypass this: a confirm-gated tool only *stages* a pending
action and returns a question for the model to speak. Only the `confirm` tool
with decision "yes" executes it, and only within the TTL.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable, Dict, Optional


@dataclass
class PendingAction:
    tool: str
    args: Dict[str, Any]
    summary: str
    execute: Callable[[], Awaitable[Dict[str, Any]]]
    created_at: float = field(default_factory=time.monotonic)


class ConfirmationPolicy:
    def __init__(self, ttl_seconds: float = 20.0, trust_terminal_input: bool = False) -> None:
        self.ttl_seconds = ttl_seconds
        self.trust_terminal_input = trust_terminal_input
        self._pending: Optional[PendingAction] = None

    # -- staging ---------------------------------------------------------

    def stage(
        self,
        tool: str,
        args: Dict[str, Any],
        summary: str,
        execute: Callable[[], Awaitable[Dict[str, Any]]],
    ) -> Dict[str, Any]:
        self._pending = PendingAction(tool=tool, args=args, summary=summary, execute=execute)
        return {
            "ok": True,
            "status": "needs_confirmation",
            "say": f"{summary} Say yes to confirm.",
            "pending_tool": tool,
        }

    @property
    def pending(self) -> Optional[PendingAction]:
        p = self._pending
        if p is None:
            return None
        if time.monotonic() - p.created_at > self.ttl_seconds:
            self._pending = None
            return None
        return p

    def cancel(self) -> Optional[PendingAction]:
        p = self._pending
        self._pending = None
        return p

    # -- decision --------------------------------------------------------

    async def decide(self, decision: str) -> Dict[str, Any]:
        d = (decision or "").strip().lower()
        yes = d in {"yes", "y", "confirm", "confirmed", "ok", "okay", "do it", "go ahead", "sure", "true"}
        p = self.pending
        if p is None:
            self._pending = None
            return {"ok": False, "status": "nothing_pending", "say": "There is nothing waiting for confirmation."}
        self._pending = None
        if not yes:
            return {"ok": True, "status": "cancelled", "say": "Cancelled."}
        return await p.execute()
