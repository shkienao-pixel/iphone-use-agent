#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/phone-harness-runtime-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT

# Only adapt the production engine's image import to the offline Mac image fake.
python3 - "$project_dir/PhoneAgent/Services/AgentEngine.swift" "$check_dir/Engine.swift" "$project_dir/Tests/ProductState/Environment.swift" "$check_dir/Environment.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
assert source.count('import UIKit') == 1
Path(sys.argv[2]).write_text(source.replace('import UIKit', 'import CoreGraphics'))
# Keep the shared fake untouched. This suite alone varies each independent
# geometry field and the actual CGImage dimensions to test cache isolation.
source = Path(sys.argv[3]).read_text()
replacements = {
    'let capturedAt: Date, fullDisplay = true': 'let capturedAt: Date\n    var fullDisplay = true',
    'let width = 2, height = 2, sourceWidth = 2, sourceHeight = 2': 'var width = 2, height = 2, sourceWidth = 2, sourceHeight = 2',
    'let image: UIImage, jpeg: Data': 'var image: UIImage\n    let jpeg: Data',
    'let cgImage: CGImage?': 'let cgImage: CGImage?\n    init(cgImage: CGImage) { self.cgImage = cgImage }',
}
for before, after in replacements.items():
    assert source.count(before) == 1, before
    source = source.replace(before, after)
assert source.count('var selectedID: String? = \"offline-device\"') == 1
source = source.replace('var selectedID: String? = \"offline-device\"', 'var selectedID: String? = \"offline-device\"\n    var pointerConnectionGeneration = UUID()')
assert source.count('var actions: [AgentAction.Kind] = []') == 1
source = source.replace('var actions: [AgentAction.Kind] = []', 'var actions: [AgentAction.Kind] = []\n    var onAction: ((AgentAction) -> Void)?')
assert source.count('actions.append(action.kind); dispatched.append(action)') == 1
source = source.replace('actions.append(action.kind); dispatched.append(action)', 'actions.append(action.kind); dispatched.append(action); onAction?(action)')
Path(sys.argv[4]).write_text(source)
PY
xcrun swiftc -module-cache-path "$check_dir/module-cache" -parse-as-library \
  "$project_dir/Shared/FrameReadiness.swift" "$project_dir/Shared/RunMetrics.swift" "$project_dir/Shared/TaskCheckpointPolicy.swift" \
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
  "$project_dir/Tests/HarnessRuntime/RuntimeCacheChecks.swift" \
  "$project_dir/Tests/HarnessRuntime/RuntimeMetricsChecks.swift" \
  "$project_dir/Tests/HarnessRuntime/PilotReplayChecks.swift" \
  "$project_dir/Tests/HarnessRuntime/main.swift" \
  -o "$check_dir/phone-harness-runtime-checks"
"$check_dir/phone-harness-runtime-checks"
