#!/usr/bin/env bash
set -euo pipefail
target_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="${PHONE_TEST_SOURCE_ROOT:-$(cd "$target_dir/../.." && pwd)}"
if [[ $# -gt 1 ]]; then
  echo "Usage: bash Tests/ManualOwnership/run.sh [fresh-results-directory]" >&2
  exit 2
fi
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/manual-ownership-checks.XXXXXX")"
output_dir="${1:-$check_dir/results}"
if [[ -e "$output_dir" ]]; then
  echo "Preserve earlier results; pass a fresh path. Evidence directory: $check_dir" >&2
  exit 2
fi
compile_exit="not_started"
run_exit="not_started"
input_digest="$(python3 "$target_dir/InputIdentity.py" create "$project_dir" "$target_dir" "$check_dir/inputs.json")"
finish_checks() {
  local result=$?
  trap - EXIT
  if ! python3 "$target_dir/InputIdentity.py" check "$project_dir" "$target_dir" "$check_dir/inputs.json" "$input_digest"; then
    result=1
  fi
  python3 - "$check_dir" "$output_dir" "$result" "$compile_exit" "$run_exit" <<'PY'
from pathlib import Path
from datetime import datetime,timezone
import json,sys
work,results=map(Path,sys.argv[1:3])
(work/'runner-exit.json').write_text(json.dumps({
 'schemaVersion':1,'observedUTC':datetime.now(timezone.utc).isoformat(),
 'exitCode':int(sys.argv[3]),'compileExitCode':sys.argv[4],'runExitCode':sys.argv[5],
 'evidenceDirectory':str(work),'resultsDirectory':str(results),
 'scope':'extracted-method/scaffold only; not complete VM/UI/voice/queue/BLE',
},indent=2)+'\n')
PY
  # Delete only disposable compiler cache; preserve all failure logs/evidence.
  rm -rf "$check_dir/module-cache"
  echo "ManualOwnership evidence preserved: $check_dir"
  exit "$result"
}
trap finish_checks EXIT
echo "ManualOwnership inputs captured: sha256:$input_digest"
python3 "$target_dir/ExtractProduction.py" "$project_dir" "$target_dir" "$check_dir/extracted"
if xcrun swiftc -O -parse-as-library -module-cache-path "$check_dir/module-cache" \
    "$project_dir/Shared/InputReleaseController.swift" "$check_dir/extracted/Environment.swift" \
    "$target_dir/main.swift" -o "$check_dir/manual-ownership-scaffold" > "$check_dir/compile.log" 2>&1; then
  compile_exit=0
else
  compile_exit=$?
  cat "$check_dir/compile.log" >&2
  exit "$compile_exit"
fi
if python3 "$target_dir/RunWithTimeout.py" "$check_dir/manual-ownership-scaffold" "$output_dir"; then
  run_exit=0
else
  run_exit=$?
  exit "$run_exit"
fi
