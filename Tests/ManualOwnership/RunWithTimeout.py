#!/usr/bin/env python3
"""Future whole-process deadman, additional to per-case bounded cleanup."""
from pathlib import Path
from datetime import datetime, timezone
import json
import os
import signal
import subprocess
import sys
import time

binary, results = map(lambda value: Path(value).resolve(), sys.argv[1:])
assert not results.exists(), "Preserve every prior result"
started = datetime.now(timezone.utc).isoformat()
clock = time.monotonic()
process = subprocess.Popen([str(binary), str(results)], stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, start_new_session=True)
timed_out = False
kill_required = False
try:
    stdout, stderr = process.communicate(timeout=20)
except subprocess.TimeoutExpired:
    timed_out = True
    os.killpg(process.pid, signal.SIGTERM)
    try:
        stdout, stderr = process.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        kill_required = True
        os.killpg(process.pid, signal.SIGKILL)
        stdout, stderr = process.communicate()
results.mkdir(parents=True, exist_ok=True)
(results / "process.stdout.log").write_bytes(stdout)
(results / "process.stderr.log").write_bytes(stderr)
(results / "process-result.json").write_text(json.dumps({
    "schemaVersion": 1, "command": [str(binary), str(results)],
    "startedUTC": started, "endedObservedUTC": datetime.now(timezone.utc).isoformat(),
    "elapsedMonotonicSeconds": time.monotonic() - clock, "exitCode": process.returncode,
    "wholeProcessDeadlineSeconds": 20, "terminationGraceSeconds": 3,
    "timedOut": timed_out, "killRequired": kill_required,
    "scope": "extracted-method/scaffold process only; not complete VM/UI/queue/voice",
}, indent=2) + "\n")
sys.stdout.buffer.write(stdout)
sys.stderr.buffer.write(stderr)
raise SystemExit(1 if timed_out else process.returncode)
