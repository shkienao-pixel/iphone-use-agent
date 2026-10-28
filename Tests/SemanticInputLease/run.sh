#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/semantic-input-lease.XXXXXX")"
output_dir="${1:-$check_dir/results}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
trap 'echo "Semantic input lease evidence: $output_dir; temporary build: $check_dir"' EXIT
# Reuse the observation suite's existing exact production frame/interface
# extraction without modifying its shared environment or extractor.
python3 "$project_dir/Tests/ContextLease/ExtractProduction.py" extract "$project_dir" "$output_dir/extracted"
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
 "$project_dir/Shared/FrameReadiness.swift" "$project_dir/Shared/RunMetrics.swift" \
 "$project_dir/Shared/PhonePageAdapters.swift" "$project_dir/Shared/XiaohongshuPageAdapter.swift" \
 "$project_dir/Shared/SystemToolRequest.swift" "$project_dir/Shared/PhoneHarness.swift" "$project_dir/Shared/TaskCheckpointPolicy.swift" \
 "$project_dir/Shared/ComposerAttachment.swift" "$project_dir/Shared/NativeTaskResult.swift" "$project_dir/Shared/AgentModels.swift" "$project_dir/Shared/MouseProtocol.swift" \
 "$project_dir/Shared/PhoneVisualControls.swift" "$project_dir/Shared/PhoneOverlayClassifier.swift" \
 "$project_dir/PhoneAgent/Services/PhoneRasterEvidence.swift" \
 "$project_dir/PhoneAgent/Services/WorkflowObservationLease.swift" "$project_dir/PhoneAgent/Services/PhoneHarnessRuntime.swift" \
 "$output_dir/extracted/Environment.swift" "$output_dir/extracted/HarnessInterface.swift" \
 "$project_dir/Tests/SemanticInputLease/main.swift" -o "$check_dir/checks" > "$output_dir/compile.log" 2>&1
"$check_dir/checks" "$output_dir" > "$output_dir/run.log" 2>&1
cat "$output_dir/run.log"
python3 "$project_dir/Tests/ContextLease/ExtractProduction.py" verify "$project_dir" "$output_dir/extracted"
rm -rf "$check_dir"
