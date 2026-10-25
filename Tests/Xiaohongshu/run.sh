#!/usr/bin/env bash
set -euo pipefail
project_dir="${PHONE_TEST_SOURCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/xiaohongshu-checks.XXXXXX")"
compile_exit="not_started"
run_exit="not_started"
input_digest="$(python3 "$project_dir/scripts/check-inputs.py" create "$project_dir" "$check_dir/inputs.json")"
finish_checks() {
  local result=$?
  trap - EXIT
  if ! python3 "$project_dir/scripts/check-inputs.py" check "$project_dir" "$check_dir/inputs.json" --expected-digest "$input_digest"; then
    result=1
  fi
  python3 - "$check_dir" "$project_dir" "$result" "$compile_exit" "$run_exit" <<'PY'
from pathlib import Path
from datetime import datetime,timezone
import json,sys
work=Path(sys.argv[1])
(work/'runner-exit.json').write_text(json.dumps({
 'schemaVersion':1,'observedUTC':datetime.now(timezone.utc).isoformat(),
 'sourceRoot':sys.argv[2],'exitCode':int(sys.argv[3]),
 'compileExitCode':sys.argv[4],'runWrapperExitCode':sys.argv[5],
 'evidenceDirectory':str(work),'failureArtifactsRetained':True,
 'scope':'old302 plus native115 and derived160 controls; no phone/model/performance acceptance',
},indent=2)+'\n')
PY
  if [[ "$result" == "0" ]]; then rm -rf "$check_dir/module-cache"; fi
  echo "Xiaohongshu test evidence preserved: $check_dir"
  exit "$result"
}
trap finish_checks EXIT
echo "Xiaohongshu complete root inputs captured: sha256:$input_digest"
if xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/PhoneHarness.swift" \
  "$project_dir/Shared/PhonePageAdapters.swift" \
  "$project_dir/Shared/XiaohongshuPageAdapter.swift" \
  "$project_dir/Shared/XiaohongshuCollection.swift" \
  "$project_dir/PhoneAgent/Stores/XiaohongshuCollectionStore.swift" \
  "$project_dir/PhoneAgent/Services/XiaohongshuCollector.swift" \
  "$project_dir/PhoneAgent/Services/XiaohongshuNavigationDriver.swift" \
  "$project_dir/PhoneAgent/Services/XiaohongshuAnalysisService.swift" \
  "$project_dir/Tests/Xiaohongshu/main.swift" \
  "$project_dir/Tests/Xiaohongshu/AdapterChecks.swift" \
  "$project_dir/Tests/Xiaohongshu/NativeLatestChecks.swift" \
  "$project_dir/Tests/Xiaohongshu/ScopeRenewalChecks.swift" \
  "$project_dir/Tests/Xiaohongshu/SourceCompletionChecks.swift" \
  "$project_dir/Tests/Xiaohongshu/XHSAnalysisWrapperChecks.swift" \
  "$project_dir/Tests/Xiaohongshu/XHSDerivedValidationChecks.swift" \
  "$project_dir/Tests/Xiaohongshu/LongReadingChecks.swift" \
  -o "$check_dir/xiaohongshu-checks" > "$check_dir/compile.log" 2>&1; then
  compile_exit=0
else
  compile_exit=$?
  cat "$check_dir/compile.log" >&2
  exit "$compile_exit"
fi
if python3 "$project_dir/Tests/Xiaohongshu/RunChecks.py" "$check_dir/xiaohongshu-checks" \
    "$project_dir/Tests/Xiaohongshu/Fixtures/analysis-wrapper-cold10.json" \
    "$check_dir/analysis-wrapper-report.json" "$check_dir"; then
  run_exit=0
else
  run_exit=$?
  exit "$run_exit"
fi
