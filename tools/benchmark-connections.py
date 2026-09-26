#!/usr/bin/env python3
"""Measure cold/repeated SSH calls without imposing fragile speed thresholds.

The source tree can be a separate release checkout.  Test fixtures and logs stay
under this checkout's .runtime; no running external SSH inventory is used.
"""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT, help="Project source checkout to measure")
    parser.add_argument("--label", required=True, help="Stable result label, e.g. release-1.0 or persistent-pool")
    parser.add_argument("--count", type=int, default=6)
    parser.add_argument("--output", type=Path, default=ROOT / "docs/connection-performance.json")
    options = parser.parse_args()
    if options.count < 2:
        parser.error("at least two calls are required to compare first and repeated requests")
    source = options.source.resolve()
    runtime = ROOT / ".runtime"
    runtime.mkdir(exist_ok=True)
    result_file = runtime / "connection-benchmark-result.json"
    env = dict(os.environ, MULTIHOST_LAB_ROOT=str(runtime / "lab"),
               MULTIHOST_BENCH_RESULT=str(result_file), MULTIHOST_BENCH_COUNT=str(options.count),
               PATH=str(runtime / "lab/bin") + os.pathsep + os.environ["PATH"])
    try:
        subprocess.run(["python3", str(ROOT / "tools/lab.py"), "start"], check=True)
        slow_bin = runtime / "lab/benchmark-slow-bin"
        slow_bin.mkdir(mode=0o700, exist_ok=True)
        wrapper = slow_bin / "ssh"
        wrapper.write_text("#!/bin/sh\ncase \" $* \" in *' -G '*) ;; *) sleep 1.2 ;; esac\n"
                           "exec /usr/bin/ssh -F " + shlex.quote(str(runtime / "lab/ssh_config")) + ' "$@"\n')
        wrapper.chmod(0o700)
        init = runtime / "lab/benchmark-slow-init.el"
        init.write_text("(load " + json.dumps(str(runtime / "lab/worker-init.el")) + " nil t)\n"
                        "(setq exec-path (cons " + json.dumps(str(slow_bin)) + " exec-path))\n"
                        "(setenv \"PATH\" (concat " + json.dumps(str(slow_bin)) + " \":\" (getenv \"PATH\")))\n")
        init.chmod(0o600)
        env["MULTIHOST_BENCH_SLOW_INIT_FILE"] = str(init)
        subprocess.run([os.environ.get("EMACS", "emacs"), "-Q", "--batch", "-L", str(source),
                        "--eval", "(setq load-prefer-newer t)",
                        "-l", str(runtime / "lab/worker-init.el"),
                        "-l", str(ROOT / "tools/benchmark-connections.el")],
                       env=env, check=True, cwd=source)
    finally:
        subprocess.run(["python3", str(ROOT / "tools/lab.py"), "stop"], check=True)
    measurement = json.loads(result_file.read_text())
    rows = measurement["scheduled"]
    measurement["distinct_worker_pids"] = len({row["value"]["worker_pid"] for row in rows})
    measurement["distinct_ssh_connections"] = len({row["value"]["stdout"].splitlines()[0] for row in rows})
    measurement.update(label=options.label,
                       measured_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                       system=platform.platform(),
                       source_sha256={p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                      for p in source.glob("*.el")})
    document = (json.loads(options.output.read_text()) if options.output.exists()
                else {"schema": 1, "environment": "two loopback SSH endpoints on one Linux kernel",
                      "interpretation": ["Elapsed time includes worker startup and connection initialization.",
                                         "Repeated v1.0 calls still create fresh Emacs and SSH processes.",
                                         "Parent timer gaps are a responsiveness proxy, not a full GUI input-latency measurement.",
                                         "Measurements are observations; tests do not require a speedup threshold."],
                      "measurements": []})
    document["measurements"] = [row for row in document["measurements"] if row["label"] != options.label] + [measurement]
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(json.dumps(document, indent=2) + "\n")
    print(json.dumps(measurement, indent=2))


if __name__ == "__main__":
    main()
