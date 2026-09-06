"""Shell context for the focused terminal: working directory, git branch, and
folder lookup. Pure local work (procfs-equivalents via ps/lsof, Spotlight,
a bounded find); nothing here talks to cmux except through the tty the
socket already reports."""

from __future__ import annotations

import os
import re
import shlex
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Optional

_SKIP_DIRS = {"node_modules", ".git", ".venv", "venv", "__pycache__", "DerivedData", "Library", ".Trash", "dist", "build", ".cache"}
_DEFAULT_ROOTS = ["~/Local-Projects", "~/Projects", "~/conductor-workspaces", "~/Developer", "~/Documents", "~/Desktop", "~/Downloads", "~"]


@dataclass
class ShellContext:
    cwd: Optional[str]
    git_branch: Optional[str]
    git_root: Optional[str]

    def summary(self) -> str:
        parts = []
        if self.cwd:
            parts.append(f"cwd: {_tilde(self.cwd)}")
        if self.git_branch:
            parts.append(f"git branch: {self.git_branch}")
        return "; ".join(parts) if parts else "cwd unknown"


def _run(cmd: List[str], timeout: float = 3.0) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def cwd_for_tty(tty: Optional[str]) -> Optional[str]:
    """The working directory of the newest process on a tty (the shell or what it is running)."""
    if not tty:
        return None
    name = tty.split("/")[-1]
    out = _run(["ps", "-t", name, "-o", "pid="])
    pids = [p.strip() for p in out.splitlines() if p.strip()]
    if not pids:
        return None
    for pid in reversed(pids):
        lsof = _run(["lsof", "-a", "-p", pid, "-d", "cwd", "-Fn"])
        for line in lsof.splitlines():
            if line.startswith("n") and line[1:].startswith("/"):
                return line[1:]
    return None


def git_info(cwd: Optional[str]) -> tuple[Optional[str], Optional[str]]:
    if not cwd or not os.path.isdir(cwd):
        return None, None
    root = _run(["git", "-C", cwd, "rev-parse", "--show-toplevel"]).strip() or None
    if not root:
        return None, None
    branch = _run(["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"]).strip() or None
    return branch, root


def shell_context(tty: Optional[str], fallback_cwd: Optional[str] = None) -> ShellContext:
    cwd = cwd_for_tty(tty) or fallback_cwd
    branch, root = git_info(cwd)
    return ShellContext(cwd=cwd, git_branch=branch, git_root=root)


# ------------------------------------------------------------------ folders


def _norm(s: str) -> str:
    return re.sub(r"[\s_\-\.]+", "", s).lower()


def _match_score(name: str, wanted: str) -> int:
    """Higher is better: exact > prefix > substring > fuzzy token overlap."""
    n, w = _norm(name), _norm(wanted)
    if not w:
        return 0
    if n == w:
        return 100
    if n.startswith(w):
        return 80
    if w in n:
        return 60
    return 0


def _walk(root: Path, max_depth: int, limit: int = 4000) -> Iterable[Path]:
    root = root.expanduser()
    if not root.is_dir():
        return
    count = 0
    for dirpath, dirnames, _ in os.walk(root):
        depth = len(Path(dirpath).relative_to(root).parts)
        dirnames[:] = [d for d in dirnames if d not in _SKIP_DIRS and not d.startswith(".")]
        if depth >= max_depth:
            dirnames[:] = []
        for d in dirnames:
            yield Path(dirpath) / d
            count += 1
            if count >= limit:
                return


def find_directories(
    name: str,
    *,
    parent: Optional[str] = None,
    cwd: Optional[str] = None,
    roots: Optional[List[str]] = None,
    limit: int = 6,
) -> List[str]:
    """Candidate directories for a spoken folder name, best first.

    Order: under the cwd (depth 3), then Spotlight by folder name, then a
    bounded walk of common project roots. `parent` filters to candidates whose
    path contains that folder name.
    """
    wanted = name.strip().rstrip("/")
    if not wanted:
        return []
    # Match on the last path component the user said ("src/lib" -> "lib",
    # "/Users/me/proj" -> "proj"); the full path is checked separately below.
    leaf = Path(os.path.expanduser(wanted)).name or wanted
    scored: dict[str, int] = {}

    def consider(path: Path, bonus: int) -> None:
        p = str(path.resolve()) if path.exists() else str(path)
        if not os.path.isdir(p):
            return
        score = _match_score(path.name, leaf)
        if score == 0:
            return
        if parent and _norm(parent) not in _norm(p.replace("/", " ")):
            return
        scored[p] = max(scored.get(p, 0), score + bonus)

    # 1) Relative to the current directory (also handles "src/lib" style paths).
    if cwd:
        direct = Path(cwd) / os.path.expanduser(wanted)
        if direct.is_dir():
            consider(direct, 40)
        for p in _walk(Path(cwd), max_depth=3, limit=1500):
            consider(p, 30)
    home = Path.home()
    expanded = Path(os.path.expanduser(wanted))
    if expanded.is_absolute() and expanded.is_dir():
        consider(expanded, 50)
    # 2) Spotlight (fast, indexed).
    out = _run(["mdfind", "-onlyin", str(home), f'kMDItemContentType == "public.folder" && kMDItemFSName == "{leaf}"c'], timeout=2.5)
    for line in out.splitlines():
        if line and not any(f"/{s}/" in line for s in _SKIP_DIRS):
            consider(Path(line), 20)
    # 3) Bounded walk of project roots.
    for root in roots or _DEFAULT_ROOTS:
        for p in _walk(Path(root), max_depth=3 if root != "~" else 2, limit=2500):
            consider(p, 10)

    ranked = sorted(scored.items(), key=lambda kv: (-kv[1], len(kv[0]), kv[0]))
    return [p for p, _ in ranked[:limit]]


def cd_command(path: str) -> str:
    return f"cd {shlex.quote(path)}"


def _tilde(path: str) -> str:
    home = str(Path.home())
    return "~" + path[len(home):] if path.startswith(home) else path


def speakable(path: str) -> str:
    return _tilde(path)
