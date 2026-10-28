#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/workflow-lease-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
python3 "$project_dir/Tests/WorkflowLease/ExtractProduction.py" "$project_dir" "$check_dir"
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
 "$project_dir/Shared/FrameReadiness.swift" "$project_dir/Shared/RunMetrics.swift" \
 "$project_dir/Shared/PhonePageAdapters.swift" "$project_dir/Shared/XiaohongshuPageAdapter.swift" \
 "$project_dir/Shared/SystemToolRequest.swift" "$project_dir/Shared/PhoneHarness.swift" "$project_dir/Shared/TaskCheckpointPolicy.swift" \
 "$project_dir/Shared/ComposerAttachment.swift" "$project_dir/Shared/AgentModels.swift" "$project_dir/Shared/MouseProtocol.swift" \
 "$project_dir/Shared/PhoneVisualControls.swift" "$project_dir/Shared/PhoneOverlayClassifier.swift" \
 "$project_dir/Shared/WorkflowDiagnostics.swift" \
 "$project_dir/PhoneAgent/Services/PhoneRasterEvidence.swift" \
 "$project_dir/PhoneAgent/Stores/WorkflowDiagnosticsStore.swift" \
 "$project_dir/PhoneAgent/Services/WorkflowObservationLease.swift" \
 "$project_dir/PhoneAgent/Services/PhoneHarnessRuntime.swift" \
 "$check_dir/DriverCore.swift" "$check_dir/Environment.swift" "$check_dir/HarnessInterface.swift" "$check_dir/IdleConstructor.swift" \
 "$project_dir/Tests/WorkflowIntegration/WorkflowLeaseChecks.swift" \
 "$project_dir/Tests/WorkflowLease/main.swift" -o "$check_dir/workflow-lease-checks"
"$check_dir/workflow-lease-checks"
