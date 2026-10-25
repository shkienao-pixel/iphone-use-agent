#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/phone-harness-workflow-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT

# Only adapt the production engine's image import to the offline Mac image fake.
python3 - "$project_dir/PhoneAgent/Services/AgentEngine.swift" "$check_dir/Engine.swift" "$project_dir/Tests/ProductState/Environment.swift" "$check_dir/Environment.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
assert source.count('import UIKit') == 1
Path(sys.argv[2]).write_text(source.replace('import UIKit', 'import CoreGraphics'))
source = Path(sys.argv[3]).read_text()
assert source.count('var selectedID: String? = \"offline-device\"') == 1
source = source.replace('var selectedID: String? = \"offline-device\"', 'var selectedID: String? = \"offline-device\"\n    var pointerConnectionGeneration = UUID()')
Path(sys.argv[4]).write_text(source)
PY
xcrun swiftc -module-cache-path "$check_dir/module-cache" -parse-as-library \
  "$project_dir/Shared/FrameReadiness.swift" "$project_dir/Shared/RunMetrics.swift" \
  "$project_dir/Shared/PhonePageAdapters.swift" "$project_dir/Shared/XiaohongshuPageAdapter.swift" \
  "$project_dir/Shared/SystemToolRequest.swift" \
  "$project_dir/Shared/PhoneHarness.swift" \
  "$project_dir/Shared/ComposerAttachment.swift" "$project_dir/Shared/AgentModels.swift" \
  "$project_dir/Shared/MouseProtocol.swift" \
  "$project_dir/Shared/VoiceCommand.swift" \
  "$project_dir/Shared/ModelHistoryContext.swift" \
  "$project_dir/Shared/NativeTaskResult.swift" "$project_dir/Shared/NativePlanningRecovery.swift" "$project_dir/PhoneAgent/Stores/TaskHistoryStore.swift" \
  "$project_dir/PhoneAgent/Services/PrivacyConsent.swift" \
  "$check_dir/Environment.swift" \
  "$check_dir/Engine.swift" \
  "$project_dir/Shared/PhoneVisualControls.swift" "$project_dir/PhoneAgent/Services/PhoneRasterEvidence.swift" \
  "$project_dir/Shared/PhoneOverlayClassifier.swift" \
  "$project_dir/PhoneAgent/Services/WorkflowObservationLease.swift" \
  "$project_dir/PhoneAgent/Services/PhoneHarnessRuntime.swift" \
  "$project_dir/Tests/HarnessWorkflows/main.swift" \
  -o "$check_dir/phone-harness-workflow-checks"
"$check_dir/phone-harness-workflow-checks"
