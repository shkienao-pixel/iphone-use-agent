#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/semantic-dispatch.XXXXXX")"
output_dir="${1:-$check_dir/results}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
trap 'echo "Semantic dispatch evidence: $output_dir; temporary build: $check_dir"' EXIT
python3 "$project_dir/Tests/SemanticDispatch/ExtractProduction.py" "$project_dir" "$output_dir/extracted"
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
 "$project_dir/Shared/FrameReadiness.swift" "$project_dir/Shared/RunMetrics.swift" \
 "$project_dir/Shared/PhonePageAdapters.swift" "$project_dir/Shared/XiaohongshuPageAdapter.swift" \
 "$project_dir/Shared/SystemToolRequest.swift" "$project_dir/Shared/PhoneHarness.swift" "$project_dir/Shared/TaskCheckpointPolicy.swift" \
 "$project_dir/Shared/ComposerAttachment.swift" "$project_dir/Shared/NativeTaskResult.swift" "$project_dir/Shared/AgentModels.swift" "$project_dir/Shared/MouseProtocol.swift" \
 "$project_dir/Shared/PhoneVisualControls.swift" "$project_dir/Shared/PhoneOverlayClassifier.swift" "$project_dir/Shared/InputReleaseController.swift" \
 "$project_dir/PhoneAgent/Services/PhoneRasterEvidence.swift" "$project_dir/PhoneAgent/Services/HIDKeyboard.swift" \
 "$project_dir/PhoneAgent/Services/WorkflowObservationLease.swift" "$project_dir/PhoneAgent/Services/PhoneHarnessRuntime.swift" "$project_dir/PhoneAgent/Services/MouseExecutor.swift" \
 "$output_dir/extracted/Environment.swift" "$output_dir/extracted/context/HarnessInterface.swift" \
 "$project_dir/Tests/SemanticDispatch/main.swift" -o "$check_dir/checks" > "$output_dir/compile.log" 2>&1
"$check_dir/checks" "$output_dir" > "$output_dir/run.log" 2>&1
cat "$output_dir/run.log"
python3 - "$project_dir" "$output_dir/extracted/source-inputs.json" <<'PY'
import hashlib,json,sys
from pathlib import Path
root, manifest = Path(sys.argv[1]),Path(sys.argv[2])
expected = json.loads(manifest.read_text())
assert all(hashlib.sha256((root / path).read_bytes()).hexdigest() == value for path,value in expected.items()), 'SemanticDispatch source changed during replay'
print('SemanticDispatch source identity verified: '+str(len(expected))+' inputs')
PY
rm -rf "$check_dir"
