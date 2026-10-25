#!/usr/bin/env python3
"""Bound the synthetic test process and retain its actual exit and artifacts."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import os
import signal
import subprocess
import sys
import time

binary, fixture, report, work = map(lambda value: Path(value).resolve(), sys.argv[1:])
assert work.is_dir() and report.parent == work and not report.exists()
fixture_before = fixture.read_bytes()
expected = fixture.with_suffix(".sha256").read_text().split()[0]
assert hashlib.sha256(fixture_before).hexdigest() == expected, "Tests fixture differs from its checked SHA"
replay_tmp = work / "replay-tmp"
replay_tmp.mkdir()
environment = os.environ.copy()
environment["TMPDIR"] = str(replay_tmp) + "/"
argv = [str(binary), str(fixture), str(report)]
started = datetime.now(timezone.utc).isoformat()
clock = time.monotonic()
process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           env=environment, start_new_session=True)
timed_out = False
kill_required = False
try:
    stdout, stderr = process.communicate(timeout=60)
except subprocess.TimeoutExpired:
    timed_out = True
    os.killpg(process.pid, signal.SIGTERM)
    try:
        stdout, stderr = process.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        kill_required = True
        os.killpg(process.pid, signal.SIGKILL)
        stdout, stderr = process.communicate()
(work / "run.stdout.log").write_bytes(stdout)
(work / "run.stderr.log").write_bytes(stderr)
fixture_after = fixture.read_bytes()
(work / "process-result.json").write_text(json.dumps({
    "schemaVersion": 1, "argv": argv,
    "argvContract": "argv1=Tests fixture, argv2=retained report; no NativeMain argv3 is used",
    "startedUTC": started, "endedObservedUTC": datetime.now(timezone.utc).isoformat(),
    "elapsedMonotonicSeconds": time.monotonic() - clock,
    "actualExitCode": process.returncode, "timedOut": timed_out,
    "processDeadlineSeconds": 60, "terminationGraceSeconds": 3, "killRequired": kill_required,
    "fixtureBytesBefore": len(fixture_before), "fixtureBytesAfter": len(fixture_after),
    "fixtureSHA256Before": hashlib.sha256(fixture_before).hexdigest(),
    "fixtureSHA256After": hashlib.sha256(fixture_after).hexdigest(),
    "scope": "only the offline test process is bounded; no model/phone or retry",
    "failureRetention": "on success main removes its own replay folder; on failure its private replay-tmp and analysis-wrapper helper best-effort copy are retained",
}, indent=2) + "\n")
sys.stdout.buffer.write(stdout)
sys.stderr.buffer.write(stderr)
assert fixture_before == fixture_after, "Tests fixture changed during replay"
raise SystemExit(1 if timed_out else process.returncode)
