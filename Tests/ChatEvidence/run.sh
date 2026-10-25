#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/chat-evidence-checks.XXXXXX")"
compile_exit="not_started"
run_exit="not_started"
input_digest="$(python3 "$project_dir/scripts/check-inputs.py" create "$project_dir" "$check_dir/inputs.json")"
finish_checks() {
  local result=$?
  local original_result="$result"
  trap - EXIT
  if ! python3 "$project_dir/scripts/check-inputs.py" check "$project_dir" "$check_dir/inputs.json" --expected-digest "$input_digest"; then
    result=1
  fi
  if python3 - "$check_dir" "$project_dir" "$result" "$original_result" "$compile_exit" "$run_exit" "$input_digest" <<'PY'
from pathlib import Path
from datetime import datetime, timezone
import json,sys
work=Path(sys.argv[1])
(work/'runner-exit.json').write_text(json.dumps({
 'schemaVersion':1,'observedUTC':datetime.now(timezone.utc).isoformat(),'sourceRoot':sys.argv[2],
 'exitCode':int(sys.argv[3]),'originalExitCode':int(sys.argv[4]),
 'compileExitCode':sys.argv[5],'runExitCode':sys.argv[6],'capturedDigest':sys.argv[7],
 'evidenceDirectory':str(work),'scope':'offline current production Reader/Store/Summarizer with injected model; no phone/API',
},indent=2)+'\n')
PY
  then
    :
  else
    if [[ "$result" == "0" ]]; then result=1; fi
    echo "Exit evidence write failed; original compile/run logs remain: $check_dir" >&2 || true
  fi
  if [[ "$result" == "0" ]]; then rm -rf "$check_dir/module-cache"; fi
  echo "ChatEvidence evidence preserved: $check_dir"
  exit "$result"
}
trap finish_checks EXIT
echo "ChatEvidence complete root inputs captured: sha256:$input_digest"
if xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Tests/ChatEvidence/Stubs.swift" \
  "$project_dir/Shared/PhoneHarness.swift" \
  "$project_dir/Shared/PhonePageAdapters.swift" \
  "$project_dir/Shared/XiaohongshuPageAdapter.swift" \
  "$project_dir/Shared/WeChatContactIdentity.swift" \
  "$project_dir/Shared/ChatEvidence.swift" \
  "$project_dir/PhoneAgent/Stores/ChatEvidenceStore.swift" \
  "$project_dir/PhoneAgent/Services/ChatEvidenceReader.swift" \
  "$project_dir/PhoneAgent/Services/ChatEvidenceSummarizer.swift" \
  "$project_dir/Tests/ChatEvidence/SummaryValidationChecks.swift" \
  "$project_dir/Tests/ChatEvidence/StoreIndexChecks.swift" \
  "$project_dir/Tests/ChatEvidence/RawCoverageChecks.swift" \
  "$project_dir/Tests/ChatEvidence/AppendTransactionChecks.swift" \
  "$project_dir/Tests/ChatEvidence/main.swift" -o "$check_dir/checks" > "$check_dir/compile.stdout.log" 2> "$check_dir/compile.stderr.log"; then
  compile_exit=0
else
  compile_exit=$?
  cat "$check_dir/compile.stdout.log" || true
  cat "$check_dir/compile.stderr.log" >&2 || true
  exit "$compile_exit"
fi
if "$check_dir/checks" "$check_dir" > "$check_dir/run.stdout.log" 2> "$check_dir/run.stderr.log"; then
  run_exit=0
else
  run_exit=$?
  cat "$check_dir/run.stdout.log" || true
  cat "$check_dir/run.stderr.log" >&2 || true
  exit "$run_exit"
fi
cat "$check_dir/run.stdout.log" || true
cat "$check_dir/run.stderr.log" >&2 || true
