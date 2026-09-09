#!/usr/bin/env python3
"""Drop Xcode compilation cache generations that the CAS no longer reads."""

from __future__ import annotations

import argparse
import fcntl
import re
import shutil
from pathlib import Path

# Xcode's compilation cache is LLVM's UnifiedOnDiskCache. Each CAS directory
# (`builtin`, `generic`, ...) chains generations named `v<version>.<n>`: the
# highest `n` is the primary store, the one before it is the upstream store
# the primary faults objects in from, and anything older is dead weight that
# the CAS deletes the next time it opens the directory. When a build ends with
# the primary over its size limit the CAS rotates in a new empty primary, so a
# warm build leaves the previous upstream behind as a dead generation that
# doubles the directory size until the next open. Pruning it here, before the
# directory is measured and uploaded, mirrors the CAS's own garbage collection.
GENERATION_PATTERN = re.compile(r"^v(\d+)\.(\d+)$")
LIVE_GENERATIONS = 2
LOCK_FILENAME = "lock"


def display_path(path: Path) -> str:
    try:
        return str(path.relative_to(Path.cwd()))
    except ValueError:
        return str(path)


def allocated_kib(path: Path) -> int:
    """Return the allocated size of a tree in KiB, like `du -sk`."""
    total_bytes = 0
    for entry in [path, *path.rglob("*")]:
        try:
            info = entry.lstat()
        except OSError:
            continue
        total_bytes += getattr(info, "st_blocks", 0) * 512
    return total_bytes // 1024


def generations_in(cas_dir: Path) -> dict[int, list[tuple[int, Path]]]:
    by_version: dict[int, list[tuple[int, Path]]] = {}
    for child in cas_dir.iterdir():
        match = GENERATION_PATTERN.match(child.name)
        if match is None or child.is_symlink() or not child.is_dir():
            continue
        version = int(match.group(1))
        number = int(match.group(2))
        by_version.setdefault(version, []).append((number, child))
    for chain in by_version.values():
        chain.sort()
    return by_version


class CASInUse(Exception):
    """Raised when another process still holds the CAS directory lock."""


def prune_cas_dir(cas_dir: Path) -> tuple[list[Path], list[Path]]:
    """Remove every generation but the newest two. Returns (kept, removed)."""
    lock_path = cas_dir / LOCK_FILENAME
    lock_file = None
    if lock_path.is_file():
        lock_file = lock_path.open("rb")
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            lock_file.close()
            raise CASInUse(str(error)) from error
    try:
        kept: list[Path] = []
        removed: list[Path] = []
        for chain in generations_in(cas_dir).values():
            for _, stale in chain[:-LIVE_GENERATIONS]:
                try:
                    shutil.rmtree(stale)
                except OSError as error:
                    # Pruning is an optimisation; never fail the build over it.
                    print(f"{display_path(stale)}: could not remove ({error}); keeping it")
                    kept.append(stale)
                    continue
                removed.append(stale)
            kept.extend(path for _, path in chain[-LIVE_GENERATIONS:])
        return kept, removed
    finally:
        if lock_file is not None:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
            lock_file.close()


def candidate_cas_dirs(cache_dir: Path) -> list[Path]:
    nested = sorted(
        child
        for child in cache_dir.iterdir()
        if child.is_dir() and not child.is_symlink()
    )
    return [cache_dir, *nested]


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Remove dead Xcode compilation cache generations after a build so "
            "the cached directory holds only the primary and upstream stores "
            "the CAS still reads. Run it after xcodebuild has exited."
        )
    )
    parser.add_argument(
        "cache_dir",
        type=Path,
        help="Xcode CompilationCache.noindex directory (under the derived data path)",
    )
    args = parser.parse_args()

    cache_dir = args.cache_dir.resolve()
    if not cache_dir.is_dir():
        print(
            f"no Xcode compilation cache at {display_path(cache_dir)}; nothing to prune"
        )
        return 0

    removed_count = 0
    removed_kib = 0
    for cas_dir in candidate_cas_dirs(cache_dir):
        if not cas_dir.is_dir():
            # Pruned away as a root-level generation earlier in this walk.
            continue
        sizes: dict[Path, int] = {}
        try:
            for chain in generations_in(cas_dir).values():
                for _, generation in chain:
                    sizes[generation] = allocated_kib(generation)
            kept, removed = prune_cas_dir(cas_dir)
        except CASInUse as error:
            print(
                f"{display_path(cas_dir)}: still in use ({error}); "
                "leaving its generations alone"
            )
            continue
        except OSError as error:
            # Unlistable or vanished directory: skip it, keep walking. The
            # bound step measures whatever is left, as it did before pruning.
            print(f"{display_path(cas_dir)}: could not inspect ({error}); leaving it alone")
            continue
        if not kept and not removed:
            continue
        kept_summary = ", ".join(f"{path.name} ({sizes[path]} KiB)" for path in kept)
        removed_summary = ", ".join(
            f"{path.name} ({sizes[path]} KiB)" for path in removed
        )
        print(
            f"{display_path(cas_dir)}: kept {kept_summary}; "
            f"removed {removed_summary or 'nothing'}"
        )
        removed_count += len(removed)
        removed_kib += sum(sizes[path] for path in removed)

    if removed_count == 0:
        print("no stale Xcode compilation cache generations found")
    else:
        print(
            f"removed {removed_count} stale Xcode compilation cache generation(s), "
            f"{removed_kib} KiB"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
