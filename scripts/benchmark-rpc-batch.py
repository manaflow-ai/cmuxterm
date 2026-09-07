#!/usr/bin/env python3
"""Compare repeated raw RPC invocations with one batch against a mock Unix server.

This measures client orchestration overhead, not terminal rendering or app latency.
Always identify whether --cli is a full built CLI or the focused adapter harness.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tests"))
from test_cli_rpc_batch import BatchServer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--requests", type=int, default=50)
    parser.add_argument("--rounds", type=int, default=7)
    args = parser.parse_args()
    if not 1 <= args.requests <= 256 or args.rounds < 1:
        parser.error("requests must be 1..256 and rounds must be positive")
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CMUX_", "CMUXD_"))}
    plan = json.dumps([{"id": f"r{i}", "method": "window.list"} for i in range(args.requests)])
    samples = {"individual": [], "batch": []}
    connections = {"individual": [], "batch": []}

    with BatchServer() as server:
        def run(mode):
            before_connections = server.connections
            before_requests = len(server.requests)
            started = time.perf_counter()
            for _ in range(args.requests if mode == "individual" else 1):
                cmd = [args.cli, "--socket", server.path]
                cmd += ["rpc", "window.list"] if mode == "individual" else ["rpc-batch", "-"]
                result = subprocess.run(cmd, input=plan if mode == "batch" else "",
                                        capture_output=True, text=True, check=True, timeout=15, env=env)
                report = json.loads(result.stdout)
                if mode == "batch":
                    assert report["ok"] and report["metrics"]["succeeded"] == args.requests
            elapsed = (time.perf_counter() - started) * 1000
            assert len(server.requests) - before_requests == args.requests
            return elapsed, server.connections - before_connections

        # Warm both paths once; alternate measured order to reduce ordering bias.
        run("individual")
        run("batch")
        for round_index in range(args.rounds):
            order = ("individual", "batch") if round_index % 2 == 0 else ("batch", "individual")
            for mode in order:
                elapsed, count = run(mode)
                samples[mode].append(elapsed)
                connections[mode].append(count)

    before = statistics.median(samples["individual"])
    after = statistics.median(samples["batch"])
    print(json.dumps({
        "benchmark": "rpc-batch-client-orchestration",
        "binary_kind": args.label,
        "server": "isolated mock Unix socket; no GUI app",
        "platform": platform.platform(),
        "requests_per_workflow": args.requests,
        "rounds": args.rounds,
        "warmup_rounds_excluded": 1,
        "individual": {"processes_per_workflow": args.requests, "connections": connections["individual"],
                       "median_ms": before, "samples_ms": samples["individual"]},
        "batch": {"processes_per_workflow": 1, "connections": connections["batch"],
                  "median_ms": after, "samples_ms": samples["batch"]},
        "median_speedup": before / after,
        "median_time_reduction_percent": (1 - after / before) * 100,
        "limitations": ["Mock responses exclude real app execution time.",
                        "Focused harness results do not measure the full CLI transport or startup."],
    }, indent=2))


if __name__ == "__main__":
    main()
