#!/usr/bin/env python3
"""Record actual checks and source digests; never declare an unrun check passed."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--unit-only', action='store_true')
    parser.add_argument('--output', type=Path, default=ROOT / '.runtime/validation.json')
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    evidence = {'started_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                'emacs': subprocess.check_output([os.environ.get('EMACS', 'emacs'), '--version'], text=True).splitlines()[0],
                'source_sha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                  for pattern in ['*.el', 'test/*.el', 'tools/lab.py', 'tools/test-integration.sh']
                                  for p in sorted(ROOT.glob(pattern))}, 'checks': []}
    commands = [['make', 'check']]
    if not args.unit_only:
        commands.append(['make', 'integration'])
    for command in commands:
        started = time.monotonic()
        run = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=900)
        log = run.stdout + run.stderr
        logfile = args.output.parent / (command[-1] + '.log')
        logfile.write_text(log)
        summaries = re.findall(r'Ran (\d+) tests, (\d+) results as expected, (\d+) unexpected', log)
        evidence['checks'].append({'command': command, 'returncode': run.returncode,
            'elapsed_seconds': round(time.monotonic() - started, 3),
            'ert_summaries': [{'total': int(a), 'expected': int(b), 'unexpected': int(c)} for a, b, c in summaries],
            'log_sha256': hashlib.sha256(log.encode()).hexdigest()})
        print(command, 'PASS' if run.returncode == 0 else 'FAIL', summaries, flush=True)
        evidence['status'] = 'passed' if all(x['returncode'] == 0 for x in evidence['checks']) else 'failed'
        args.output.write_text(json.dumps(evidence, indent=2) + '\n')
        if run.returncode:
            print(log[-10000:])
            return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
