#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/phone-run-metrics.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -module-cache-path "$check_dir/module-cache" -parse-as-library \
  "$project_dir/Shared/RunMetrics.swift" "$project_dir/Tests/RunMetrics/main.swift" -o "$check_dir/checks"
if [[ $# -gt 1 ]]; then
  echo "Usage: bash Tests/RunMetrics/run.sh [synthetic-fixture.json]" >&2
  exit 2
fi
fixture_path="${1:-$check_dir/synthetic-fixture.json}"
"$check_dir/checks" "$fixture_path"
xcrun swiftc -module-cache-path "$check_dir/module-cache" -parse-as-library \
  "$project_dir/Shared/RunMetrics.swift" "$project_dir/Tools/RunBenchmark.swift" -o "$check_dir/benchmark"
python3 - "$fixture_path" "$check_dir" <<'PYCLI'
import json, pathlib, sys
fixture = json.loads(pathlib.Path(sys.argv[1]).read_text())
root = pathlib.Path(sys.argv[2])
for group in ['before', 'after']:
    (root/group).mkdir()
    for index, sample in enumerate(fixture[group]):
        (root/group/f'{index}.json').write_text(json.dumps(sample))
PYCLI
"$check_dir/benchmark" "$check_dir/before" "$check_dir/after" "$check_dir/cli-report.json"
python3 - "$check_dir/cli-report.json" <<'PYCLI'
import json, pathlib, sys
report = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert report['comparison']['before']['samples'] == 3
assert report['comparison']['after']['samples'] == 3
assert report['comparison']['before']['outcomeCounts']['failed'] == 1
assert report['comparison']['eligibleForDeviceAcceptance'] is False
print('4 benchmark CLI statistics checks passed; synthetic clock fixture only.')
PYCLI
printf '{' > "$check_dir/before/unreadable.json"
if "$check_dir/benchmark" "$check_dir/before" "$check_dir/after" "$check_dir/should-not-exist.json" > "$check_dir/rejected.log" 2>&1; then
  echo "Malformed attempt must fail the report" >&2
  exit 1
fi
test ! -e "$check_dir/should-not-exist.json"
echo "2 benchmark CLI failure-retention checks passed."

python3 - "$project_dir/PhoneAgent/Services/AgentEngine.swift" "$check_dir/Engine.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
assert source.count('import UIKit') == 1
Path(sys.argv[2]).write_text(source.replace('import UIKit', 'import CoreGraphics'))
PY
python3 - "$project_dir/PhoneAgent/Services/WorkflowObservationLease.swift" "$check_dir/LeaseFailure.swift" <<'PYLEASE'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(); start=s.index('struct WorkflowLeaseFailure:'); end=s.index('/// Pixel recognition reuse only.')
Path(sys.argv[2]).write_text('import Foundation\n'+s[start:end])
PYLEASE
xcrun swiftc -module-cache-path "$check_dir/module-cache" -parse-as-library \
  "$project_dir/Shared/RunMetrics.swift" "$project_dir/Shared/FrameReadiness.swift" \
  "$project_dir/Shared/PhonePageAdapters.swift" "$project_dir/Shared/XiaohongshuPageAdapter.swift" "$project_dir/Shared/SystemToolRequest.swift" \
  "$project_dir/Shared/PhoneHarness.swift" "$project_dir/Shared/ComposerAttachment.swift" "$project_dir/Shared/AgentModels.swift" \
  "$project_dir/Shared/MouseProtocol.swift" "$project_dir/Shared/VoiceCommand.swift" \
  "$project_dir/Shared/ModelHistoryContext.swift" \
  "$project_dir/Shared/NativeTaskResult.swift" "$project_dir/Shared/NativePlanningRecovery.swift" "$project_dir/PhoneAgent/Stores/TaskHistoryStore.swift" "$project_dir/PhoneAgent/Services/PrivacyConsent.swift" \
  "$project_dir/Tests/ProductState/Environment.swift" "$check_dir/LeaseFailure.swift" "$check_dir/Engine.swift" \
  "$project_dir/Tests/RunMetrics/EngineChecks.swift" -o "$check_dir/engine-checks"
"$check_dir/engine-checks"
