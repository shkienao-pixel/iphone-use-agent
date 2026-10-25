#!/usr/bin/env python3
"""Sample only this command's process tree and the dedicated simulator app."""
import argparse
import datetime
import json
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--device", default="911137A1-574C-4CAF-B1C2-062E268C95A3")
parser.add_argument("command", nargs=argparse.REMAINDER)
args = parser.parse_args()
command = args.command[1:] if args.command[:1] == ["--"] else args.command
if not command:
    parser.error("A command is required")
args.output.mkdir(parents=True, exist_ok=True)
device = args.device
started = time.monotonic()
samples = []
peak_tree = peak_app = peak_widget = 0
swap_before = subprocess.check_output(["sysctl", "-n", "vm.swapusage"], text=True).strip()
with (args.output / "run.log").open("w") as stream:
    process = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT)
    while True:
        rows = []
        for line in subprocess.check_output(["ps", "-axo", "pid=,ppid=,rss=,args="], text=True).splitlines():
            row = line.strip().split(None, 3)
            if len(row) == 4:
                rows.append((int(row[0]), int(row[1]), int(row[2]), row[3]))
        descendants = {process.pid}
        for _ in range(12):
            expanded = descendants | {pid for pid, parent, _, _ in rows if parent in descendants}
            if expanded == descendants:
                break
            descendants = expanded
        tree = sum(rss for pid, _, rss, _ in rows if pid in descendants)
        app = sum(rss for _, _, rss, command_line in rows if device in command_line and "/PhoneAgent.app/PhoneAgent" in command_line)
        widget = sum(rss for _, _, rss, command_line in rows if device in command_line and "/PhoneAgent.app/PlugIns/PhoneAgentActivity.appex/" in command_line)
        peak_tree, peak_app, peak_widget = max(peak_tree, tree), max(peak_app, app), max(peak_widget, widget)
        samples.append({"seconds": round(time.monotonic() - started, 2), "commandTreeRSSKiB": tree, "simulatorAppRSSKiB": app, "simulatorWidgetRSSKiB": widget})
        # Sampling storage stays bounded even if a command takes much longer.
        if len(samples) > 600:
            samples = samples[::2]
        if process.poll() is not None:
            break
        time.sleep(2)
report = {"finishedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(), "device": device, "exitCode": process.returncode,
          "elapsedSeconds": round(time.monotonic() - started, 2), "peakCommandTreeRSSMiB": round(peak_tree / 1024, 1),
          "peakSimulatorAppRSSMiB": round(peak_app / 1024, 1), "samples": samples,
          "peakSimulatorWidgetRSSMiB": round(peak_widget / 1024, 1),
          "swapBefore": swap_before, "swapAfter": subprocess.check_output(["sysctl", "-n", "vm.swapusage"], text=True).strip(),
          "scope": "2-second sampled RSS; command tree includes compiler/test runner; not a physical iPhone footprint or precise peak"}
(args.output / "resources.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({k: v for k, v in report.items() if k != "samples"}, ensure_ascii=False, indent=2))
raise SystemExit(process.returncode)
