"""UI state snapshot built from `system.tree` (+ `pane.list` for pane geometry).

The voice model never sees UUIDs or `kind:N` handle refs. It sees a compact,
numbered summary (positional 1-based numbers plus names) and refers to things
by number, name, or spatial words. This module owns both the summary and the
resolution of those references back to UUIDs.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional


@dataclass
class Surface:
    id: str
    ref: str
    title: str
    type: str  # "terminal" | "browser" | other panel kinds
    index_in_pane: int
    selected_in_pane: bool
    focused: bool
    url: Optional[str] = None

    @property
    def is_terminal(self) -> bool:
        return self.type == "terminal"

    @property
    def is_browser(self) -> bool:
        return self.type == "browser"


@dataclass
class Pane:
    id: str
    ref: str
    index: int
    focused: bool
    surfaces: List[Surface] = field(default_factory=list)
    frame: Optional[Dict[str, float]] = None  # {"x","y","width","height"} in window points
    position: str = ""  # human word such as "left", "right", "top-left"

    @property
    def number(self) -> int:
        return self.index + 1

    @property
    def selected_surface(self) -> Optional[Surface]:
        for s in self.surfaces:
            if s.selected_in_pane:
                return s
        return self.surfaces[0] if self.surfaces else None

    @property
    def center(self) -> Optional[tuple[float, float]]:
        if not self.frame:
            return None
        return (
            self.frame["x"] + self.frame["width"] / 2.0,
            self.frame["y"] + self.frame["height"] / 2.0,
        )


@dataclass
class Workspace:
    id: str
    ref: str
    index: int
    title: str
    selected: bool
    panes: List[Pane] = field(default_factory=list)

    @property
    def number(self) -> int:
        return self.index + 1

    @property
    def focused_pane(self) -> Optional[Pane]:
        for p in self.panes:
            if p.focused:
                return p
        return self.panes[0] if self.panes else None


@dataclass
class UIState:
    window_id: Optional[str]
    workspaces: List[Workspace]

    # ------------------------------------------------------------------ build

    @classmethod
    def from_tree(cls, tree: Dict[str, Any], pane_rows: Optional[List[Dict[str, Any]]] = None) -> "UIState":
        windows = list(tree.get("windows") or [])
        window = _pick_window(windows)
        workspaces: List[Workspace] = []
        for w_index, w in enumerate(window.get("workspaces") or []):
            panes: List[Pane] = []
            for p_index, p in enumerate(w.get("panes") or []):
                surfaces: List[Surface] = []
                for s_index, s in enumerate(p.get("surfaces") or []):
                    surfaces.append(
                        Surface(
                            id=str(s.get("id")),
                            ref=str(s.get("ref") or ""),
                            title=str(s.get("title") or ""),
                            type=str(s.get("type") or "terminal"),
                            index_in_pane=int(s.get("index_in_pane", s_index)),
                            selected_in_pane=bool(s.get("selected_in_pane", False)),
                            focused=bool(s.get("focused", False)),
                            url=s.get("url"),
                        )
                    )
                panes.append(
                    Pane(
                        id=str(p.get("id")),
                        ref=str(p.get("ref") or ""),
                        index=int(p.get("index", p_index)),
                        focused=bool(p.get("focused", False)),
                        surfaces=surfaces,
                    )
                )
            panes.sort(key=lambda x: x.index)
            workspaces.append(
                Workspace(
                    id=str(w.get("id")),
                    ref=str(w.get("ref") or ""),
                    index=int(w.get("index", w_index)),
                    title=str(w.get("title") or ""),
                    selected=bool(w.get("selected", False)),
                    panes=panes,
                )
            )
        workspaces.sort(key=lambda x: x.index)
        state = cls(window_id=window.get("id"), workspaces=workspaces)
        if pane_rows:
            state.apply_pane_frames(pane_rows)
        return state

    def apply_pane_frames(self, pane_rows: List[Dict[str, Any]]) -> None:
        """Attach `pane.list` pixel frames (current workspace) and derive position words."""
        ws = self.current_workspace
        if ws is None:
            return
        frames = {str(row.get("id")): row.get("pixel_frame") for row in pane_rows}
        for pane in ws.panes:
            frame = frames.get(pane.id)
            if isinstance(frame, dict) and all(k in frame for k in ("x", "y", "width", "height")):
                pane.frame = {k: float(frame[k]) for k in ("x", "y", "width", "height")}
        _assign_positions(ws.panes)

    # --------------------------------------------------------------- accessors

    @property
    def current_workspace(self) -> Optional[Workspace]:
        for w in self.workspaces:
            if w.selected:
                return w
        return self.workspaces[0] if self.workspaces else None

    @property
    def focused_pane(self) -> Optional[Pane]:
        ws = self.current_workspace
        return ws.focused_pane if ws else None

    @property
    def focused_surface(self) -> Optional[Surface]:
        pane = self.focused_pane
        if pane is None:
            return None
        for s in pane.surfaces:
            if s.focused:
                return s
        return pane.selected_surface

    def browser_surfaces(self, workspace: Optional[Workspace] = None) -> List[Surface]:
        ws = workspace or self.current_workspace
        if ws is None:
            return []
        return [s for p in ws.panes for s in p.surfaces if s.is_browser]

    # -------------------------------------------------------------- resolvers

    def resolve_workspace(self, target: Optional[str]) -> Optional[Workspace]:
        """Number (1-based), name substring, 'current'/'this', or a workspace ref."""
        if target is None or not str(target).strip():
            return self.current_workspace
        t = str(target).strip()
        low = t.lower()
        if low in {"current", "this", "here", "focused", "selected"}:
            return self.current_workspace
        if low.isdigit():
            n = int(low)
            for w in self.workspaces:
                if w.number == n:
                    return w
            return None
        if low.startswith("workspace:"):
            for w in self.workspaces:
                if w.ref == low:
                    return w
            return None
        return _best_name_match(low, [(w.title, w) for w in self.workspaces])

    def resolve_pane(self, target: Optional[str], workspace: Optional[Workspace] = None) -> Optional[Pane]:
        """Number (1-based), spatial word relative to the focused pane, 'current', or a pane ref."""
        ws = workspace or self.current_workspace
        if ws is None:
            return None
        if target is None or not str(target).strip():
            return ws.focused_pane
        low = str(target).strip().lower()
        if low in {"current", "this", "here", "focused"}:
            return ws.focused_pane
        if low.isdigit():
            n = int(low)
            for p in ws.panes:
                if p.number == n:
                    return p
            return None
        if low.startswith("pane:"):
            for p in ws.panes:
                if p.ref == low:
                    return p
            return None
        direction = _direction_word(low)
        if direction:
            return _pane_in_direction(ws.panes, ws.focused_pane, direction)
        # Positional labels such as "left" already handled; try the assigned position words.
        for p in ws.panes:
            if p.position and p.position == low:
                return p
        # Fall back to matching the pane by a surface title it contains.
        candidates = [(s.title, p) for p in ws.panes for s in p.surfaces]
        return _best_name_match(low, candidates)

    def resolve_surface(
        self,
        target: Optional[str],
        pane: Optional[Pane] = None,
        workspace: Optional[Workspace] = None,
        kind: Optional[str] = None,
    ) -> Optional[Surface]:
        """Number (1-based within the pane), title substring, 'browser'/'terminal', or a surface ref.

        With no target: the focused surface, unless `kind` is given, in which case
        the focused surface if it matches the kind, else the first surface of that
        kind in the focused pane, else anywhere in the workspace.
        """
        ws = workspace or self.current_workspace
        if ws is None:
            return None
        pane = pane or ws.focused_pane
        if target is None or not str(target).strip():
            focused = self.focused_surface if ws is self.current_workspace else (pane.selected_surface if pane else None)
            if kind is None:
                return focused
            if focused is not None and focused.type == kind:
                return focused
            if pane is not None:
                for s in pane.surfaces:
                    if s.type == kind:
                        return s
            for p in ws.panes:
                for s in p.surfaces:
                    if s.type == kind:
                        return s
            return None
        low = str(target).strip().lower()
        if low in {"current", "this", "here", "focused"}:
            return self.resolve_surface(None, pane=pane, workspace=ws, kind=kind)
        if low in {"browser", "terminal"}:
            return self.resolve_surface(None, pane=pane, workspace=ws, kind=low)
        if low.startswith("surface:"):
            for p in ws.panes:
                for s in p.surfaces:
                    if s.ref == low:
                        return s
            return None
        if low.isdigit() and pane is not None:
            n = int(low)
            for s in pane.surfaces:
                if s.index_in_pane + 1 == n:
                    return s
            return None
        pool = [(s.title, s) for p in ws.panes for s in p.surfaces if kind is None or s.type == kind]
        return _best_name_match(low, pool)

    # ---------------------------------------------------------------- summary

    def summary(self) -> str:
        if not self.workspaces:
            return "No workspaces are open."
        parts: List[str] = []
        ws_bits = []
        for w in self.workspaces:
            label = f'{w.number} "{_short(w.title)}"'
            if w.selected:
                label += " (current)"
            ws_bits.append(label)
        parts.append(f"Workspaces ({len(self.workspaces)}): " + " | ".join(ws_bits))
        ws = self.current_workspace
        if ws is not None:
            pane_bits = []
            for p in ws.panes:
                surf_bits = []
                for s in p.surfaces:
                    sb = f'{s.type} "{_short(s.title)}"'
                    if s.is_browser and s.url:
                        sb += f" [{_short(s.url, 60)}]"
                    if s.focused:
                        sb += " (focused)"
                    elif s.selected_in_pane and len(p.surfaces) > 1:
                        sb += " (shown)"
                    surf_bits.append(sb)
                pos = f" {p.position}" if p.position else ""
                pane_bits.append(f"pane {p.number}{pos}: [" + ", ".join(surf_bits) + "]")
            parts.append(f'Current workspace "{_short(ws.title)}" has {len(ws.panes)} pane(s): ' + " | ".join(pane_bits))
        return "\n".join(parts)


# ---------------------------------------------------------------------------
# helpers


def _pick_window(windows: List[Dict[str, Any]]) -> Dict[str, Any]:
    if not windows:
        return {}
    for w in windows:
        if w.get("key"):
            return w
    for w in windows:
        if w.get("visible", True):
            return w
    return windows[0]


def _short(text: str, limit: int = 40) -> str:
    text = " ".join(str(text or "").split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def _best_name_match(needle: str, candidates: List[tuple[str, Any]]) -> Any:
    """Case-insensitive match: exact, then prefix, then substring, then token overlap."""
    needle = needle.strip().lower()
    if not needle:
        return None
    norm = [(str(name or "").lower(), obj) for name, obj in candidates]
    for name, obj in norm:
        if name == needle:
            return obj
    for name, obj in norm:
        if name.startswith(needle):
            return obj
    for name, obj in norm:
        if needle in name:
            return obj
    words = set(needle.split())
    best, best_score = None, 0
    for name, obj in norm:
        score = len(words & set(name.replace("/", " ").replace("-", " ").split()))
        if score > best_score:
            best, best_score = obj, score
    return best


_DIRECTION_WORDS = {
    "left": "left",
    "right": "right",
    "up": "up",
    "above": "up",
    "top": "up",
    "down": "down",
    "below": "down",
    "bottom": "down",
}


def _direction_word(text: str) -> Optional[str]:
    t = text.strip().lower()
    for prefix in ("to the ", "the ", "on the "):
        if t.startswith(prefix):
            t = t[len(prefix):]
    t = t.replace(" pane", "").replace(" one", "").strip()
    return _DIRECTION_WORDS.get(t)


def _pane_in_direction(panes: List[Pane], origin: Optional[Pane], direction: str) -> Optional[Pane]:
    if origin is None or origin.center is None:
        return None
    ox, oy = origin.center
    best, best_dist = None, None
    for p in panes:
        if p is origin or p.center is None:
            continue
        px, py = p.center
        dx, dy = px - ox, py - oy
        if direction == "right" and dx <= 1:
            continue
        if direction == "left" and dx >= -1:
            continue
        if direction == "down" and dy <= 1:
            continue
        if direction == "up" and dy >= -1:
            continue
        # Prefer panes that overlap on the orthogonal axis; weight orthogonal distance heavily.
        if direction in ("left", "right"):
            dist = abs(dx) + 4 * abs(dy)
        else:
            dist = abs(dy) + 4 * abs(dx)
        if best_dist is None or dist < best_dist:
            best, best_dist = p, dist
    return best


def _assign_positions(panes: List[Pane]) -> None:
    framed = [p for p in panes if p.frame]
    if len(framed) < 2:
        for p in panes:
            p.position = ""
        return
    xs = _cluster(sorted({p.frame["x"] for p in framed}))
    ys = _cluster(sorted({p.frame["y"] for p in framed}))
    col_words = {1: [""], 2: ["left", "right"], 3: ["left", "middle", "right"]}
    row_words = {1: [""], 2: ["top", "bottom"], 3: ["top", "middle", "bottom"]}
    for p in framed:
        c = _bucket(p.frame["x"], xs)
        r = _bucket(p.frame["y"], ys)
        cw = col_words.get(len(xs), [f"column {i + 1}" for i in range(len(xs))])[c]
        rw = row_words.get(len(ys), [f"row {i + 1}" for i in range(len(ys))])[r]
        p.position = "-".join(w for w in (rw, cw) if w) if (rw and cw) else (rw or cw)


def _cluster(values: List[float], tolerance: float = 12.0) -> List[float]:
    out: List[float] = []
    for v in values:
        if not out or abs(v - out[-1]) > tolerance:
            out.append(v)
    return out


def _bucket(value: float, clusters: List[float]) -> int:
    best, best_d = 0, None
    for i, c in enumerate(clusters):
        d = abs(value - c)
        if best_d is None or d < best_d:
            best, best_d = i, d
    return best
