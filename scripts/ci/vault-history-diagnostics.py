#!/usr/bin/env python3
"""Temporary PR-9131 diagnostics; no application behavior changes."""

import os
from pathlib import Path
import re
import subprocess
import sys
import time


def symbols(log_path):
    text = Path(log_path).read_text(errors="replace")
    images = re.compile(
        r"(0x[0-9a-f]+)[–-](0x[0-9a-f]+)\s+([0-9a-f]{32})\s+"
        r"cmux DEV.debug.dylib\s+([^\n]+)", re.I
    )
    for number, report in enumerate(text.split("*** Signal ")[1:], 1):
        for match in images.finditer(report):
            base, end, uuid, path = match.groups()
            binary = Path(path.strip())
            root = Path(os.environ["CMUX_DERIVED_DATA_PATH"]).resolve()
            if not binary.resolve().is_relative_to(root) or not binary.is_file():
                print(f"Refusing unknown crash binary: {binary}", flush=True)
                continue
            identity = subprocess.check_output(
                ["xcrun", "dwarfdump", "--uuid", str(binary)], text=True
            )
            identities = re.findall(r"UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)", identity)
            arch = next((arch for value, arch in identities
                         if value.replace("-", "").lower() == uuid.lower()), None)
            if arch is None:
                raise RuntimeError(f"UUID mismatch: report {uuid}, binary {identity}")
            addresses = list(dict.fromkeys(
                address for address in re.findall(
                    r"^\s*\d+(?:\s+\[[^]]+\])?\s+(0x[0-9a-f]+)",
                    report, re.M | re.I
                ) if int(base, 16) <= int(address, 16) < int(end, 16)
            ))
            print(f"Report {number}: MATCHED UUID {uuid}, base {base}, arch {arch}", flush=True)
            if addresses:
                resolved = subprocess.check_output(
                    ["xcrun", "atos", "-o", str(binary), "-arch", arch,
                     "-l", base, *addresses], text=True
                )
                for address, symbol in zip(addresses, resolved.splitlines()):
                    print(f"{address}: {symbol}", flush=True)


def monitor(log_path):
    deadline = time.monotonic() + 25 * 60
    path = Path(log_path)
    while time.monotonic() < deadline:
        text = path.read_text(errors="replace") if path.exists() else ""
        if 'Click "VaultPaneTabButton.history"' in text:
            time.sleep(7)
            processes = subprocess.check_output(
                ["ps", "-axo", "pid=,command="], text=True
            )
            prefix = os.environ["CMUX_DERIVED_DATA_PATH"] + "/Build/Products/Debug/"
            for process in processes.splitlines():
                parts = process.strip().split(None, 1)
                if len(parts) != 2:
                    continue
                pid, command = parts
                if command.startswith(prefix) and ".app/Contents/MacOS/cmux DEV" in command:
                    print(f"Sampling exact test app PID {pid}: {command}", flush=True)
                    subprocess.run(
                        ["sample", pid, "5", "-file", "/tmp/vault-history-hang.sample.txt"],
                        check=False, timeout=20
                    )
            return
        time.sleep(1)


if __name__ == "__main__":
    {"symbols": symbols, "monitor": monitor}[sys.argv[1]](sys.argv[2])
