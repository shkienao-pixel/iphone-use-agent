#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/overlay-recognition.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
python3 - "$project_dir" "$check_dir" <<'PY'
from pathlib import Path
import sys
root, tmp = map(Path, sys.argv[1:])
engine = (root / 'PhoneAgent/Services/AgentEngine.swift').read_text()
assert engine.count('import UIKit') == 1
(tmp / 'Engine.swift').write_text(engine.replace('import UIKit', 'import CoreGraphics'))
# Reuse only the existing phone/model/BLE boundary fakes. Add constructors for
# actual fixture CGImage pixels; no classifier or production dispatch is faked.
environment = (root / 'Tests/ProductState/Environment.swift').read_text()
needle = '    init(shade: CGFloat = 1) {'
assert environment.count(needle) == 1
environment = environment.replace(needle, '    init(cgImage: CGImage) { self.cgImage = cgImage }\n' + needle)
needle = '    init(capturedAt: Date = Date(), captureID: UUID? = nil, shade: CGFloat = 1) {'
assert environment.count(needle) == 1
environment = environment.replace(needle, '''    init(image: UIImage, capturedAt: Date = Date(), captureID: UUID? = nil) {
        self.capturedAt = capturedAt; self.captureID = captureID; self.image = image
    }
''' + needle)
assert environment.count('var selectedID: String? = \"offline-device\"') == 1
environment = environment.replace('var selectedID: String? = \"offline-device\"', 'var selectedID: String? = \"offline-device\"\n    var pointerConnectionGeneration = UUID()')
(tmp / 'Environment.swift').write_text(environment)
PY
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/FrameReadiness.swift" "$project_dir/Shared/RunMetrics.swift" \
  "$project_dir/Shared/PhonePageAdapters.swift" "$project_dir/Shared/XiaohongshuPageAdapter.swift" \
  "$project_dir/Shared/PhoneVisualControls.swift" "$project_dir/Shared/PhoneOverlayClassifier.swift" \
  "$project_dir/Shared/SystemToolRequest.swift" "$project_dir/Shared/PhoneHarness.swift" \
  "$project_dir/Shared/ComposerAttachment.swift" "$project_dir/Shared/AgentModels.swift" "$project_dir/Shared/MouseProtocol.swift" \
  "$project_dir/Shared/VoiceCommand.swift" "$project_dir/Shared/ModelHistoryContext.swift" \
  "$project_dir/Shared/NativeTaskResult.swift" "$project_dir/Shared/NativePlanningRecovery.swift" "$project_dir/PhoneAgent/Stores/TaskHistoryStore.swift" \
  "$project_dir/PhoneAgent/Services/PrivacyConsent.swift" \
  "$project_dir/PhoneAgent/Services/PhoneRasterEvidence.swift" \
  "$check_dir/Environment.swift" "$check_dir/Engine.swift" \
  "$project_dir/PhoneAgent/Services/WorkflowObservationLease.swift" \
  "$project_dir/PhoneAgent/Services/PhoneHarnessRuntime.swift" \
  "$project_dir/Tests/OverlayRecognition/main.swift" -o "$check_dir/checks"
"$check_dir/checks"
