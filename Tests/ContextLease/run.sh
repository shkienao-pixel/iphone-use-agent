#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ $# -gt 1 ]]; then
  echo "Usage: bash Tests/ContextLease/run.sh [results-directory]" >&2
  exit 2
fi
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/context-lease-checks.XXXXXX")"
output_dir="${1:-$check_dir/results}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
compile_exit="not_started"
run_exit="not_started"
finish_checks() {
  local result=$?
  local original_result="$result"
  trap - EXIT
  if ! python3 "$project_dir/Tests/ContextLease/ExtractProduction.py" verify "$project_dir" "$output_dir"; then
    result=1
  fi
  if python3 - "$check_dir" "$output_dir" "$project_dir" "$result" "$original_result" "$compile_exit" "$run_exit" <<'PY'
from pathlib import Path
from datetime import datetime, timezone
import json,sys
work=Path(sys.argv[1])
(work/'runner-exit.json').write_text(json.dumps({
 'schemaVersion':1,'observedUTC':datetime.now(timezone.utc).isoformat(),'resultsDirectory':sys.argv[2],
 'sourceRoot':sys.argv[3],'exitCode':int(sys.argv[4]),'originalExitCode':int(sys.argv[5]),
 'compileExitCode':sys.argv[6],'runExitCode':sys.argv[7],'evidenceDirectory':str(work),
 'scope':'current source-extracted ContextLease offline controls; no phone/API',
},indent=2)+'\n')
PY
  then
    :
  else
    if [[ "$result" == "0" ]]; then result=1; fi
    echo "Exit evidence write failed; original compile/run logs remain: $check_dir" >&2 || true
  fi
  # Compile logs and extracted inputs are evidence; module caches are disposable.
  rm -rf "$check_dir/module-cache"
  echo "ContextLease evidence preserved: $check_dir; results: $output_dir"
  exit "$result"
}
trap finish_checks EXIT
python3 "$project_dir/Tests/ContextLease/ExtractProduction.py" extract "$project_dir" "$output_dir"
if xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
 "$project_dir/Shared/FrameReadiness.swift" "$project_dir/Shared/RunMetrics.swift" \
 "$project_dir/Shared/PhonePageAdapters.swift" "$project_dir/Shared/XiaohongshuPageAdapter.swift" \
 "$project_dir/Shared/SystemToolRequest.swift" "$project_dir/Shared/PhoneHarness.swift" \
 "$project_dir/Shared/ComposerAttachment.swift" "$project_dir/Shared/AgentModels.swift" "$project_dir/Shared/MouseProtocol.swift" \
 "$project_dir/Shared/PhoneVisualControls.swift" "$project_dir/Shared/PhoneOverlayClassifier.swift" \
 "$project_dir/PhoneAgent/Services/PhoneRasterEvidence.swift" \
 "$project_dir/PhoneAgent/Services/WorkflowObservationLease.swift" \
 "$project_dir/PhoneAgent/Services/PhoneHarnessRuntime.swift" \
 "$output_dir/Environment.swift" "$output_dir/HarnessInterface.swift" \
 "$output_dir/IdleConstructor.swift" "$output_dir/ObserveAction.swift" \
 "$project_dir/Tests/ContextLease/main.swift" -o "$check_dir/context-lease-checks" > "$check_dir/compile.stdout.log" 2> "$check_dir/compile.stderr.log"; then
  compile_exit=0
else
  compile_exit=$?
  cat "$check_dir/compile.stdout.log" || true
  cat "$check_dir/compile.stderr.log" >&2 || true
  exit "$compile_exit"
fi
if "$check_dir/context-lease-checks" "$output_dir" "$check_dir" > "$check_dir/run.stdout.log" 2> "$check_dir/run.stderr.log"; then
  run_exit=0
else
  run_exit=$?
  cat "$check_dir/run.stdout.log" || true
  cat "$check_dir/run.stderr.log" >&2 || true
  exit "$run_exit"
fi
cat "$check_dir/run.stdout.log" || true
cat "$check_dir/run.stderr.log" >&2 || true
