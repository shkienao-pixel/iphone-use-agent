#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/task-recovery-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
python3 "$project_dir/Tests/TaskRecovery/ExtractProduction.py" "$project_dir" "$check_dir/production"
python3 - "$project_dir/Tests/ProductState/Environment.swift" "$check_dir/CheckpointEnvironment.swift" <<'PYCHECKPOINT'
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text()
needle = 'var selectedID: String? = "offline-device"'
assert s.count(needle) == 1
s = s.replace(needle, needle + "\n    var pointerConnectionGeneration = UUID()")
Path(sys.argv[2]).write_text(s)
PYCHECKPOINT
xcrun swiftc -module-cache-path "$check_dir/module-cache" -parse-as-library \
  "$project_dir/Shared/FrameReadiness.swift" "$project_dir/Shared/RunMetrics.swift" \
  "$project_dir/Shared/PhonePageAdapters.swift" "$project_dir/Shared/XiaohongshuPageAdapter.swift" \
  "$project_dir/Shared/SystemToolRequest.swift" "$project_dir/Shared/PhoneHarness.swift" \
  "$project_dir/Shared/ComposerAttachment.swift" "$project_dir/Shared/AgentModels.swift" \
  "$project_dir/Shared/NativeCollectionTarget.swift" \
  "$project_dir/Shared/PhoneContentArtifacts.swift" \
  "$project_dir/PhoneAgent/Services/NativeContentEvidence.swift" \
  "$project_dir/Shared/MouseProtocol.swift" "$project_dir/Shared/VoiceCommand.swift" \
  "$project_dir/Shared/ModelHistoryContext.swift" \
  "$project_dir/PhoneAgent/Stores/TaskQueueStore.swift" "$project_dir/Shared/TaskCheckpointPolicy.swift" "$project_dir/Shared/NativeTaskResult.swift" "$project_dir/Shared/NativePlanningRecovery.swift" "$project_dir/PhoneAgent/Stores/TaskHistoryStore.swift" \
  "$project_dir/PhoneAgent/Services/PrivacyConsent.swift" "$project_dir/PhoneAgent/Services/BackgroundTaskCoordinator.swift" \
  "$check_dir/CheckpointEnvironment.swift" \
  "$check_dir/production/LeaseFailure.swift" "$check_dir/production/Engine.swift" \
  "$check_dir/production/Controller.swift" "$check_dir/production/ReceiptPolicy.swift" \
  "$project_dir/Tests/TaskRecovery/ReceiptPolicyChecks.swift" "$project_dir/Tests/TaskRecovery/main.swift" -o "$check_dir/checks"
"$check_dir/checks"
