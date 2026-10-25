#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/workflow-integration-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
python3 - "$project_dir" "$check_dir" <<'PY'
from pathlib import Path
import sys
root, tmp = map(Path, sys.argv[1:])
source = (root / 'PhoneAgent/Services/AgentEngine.swift').read_text()
assert source.count('import UIKit') == 1
(tmp / 'Engine.swift').write_text(source.replace('import UIKit', 'import CoreGraphics'))
# Reuse the existing I/O boundary fakes. Only make frame geometry mutable so
# resize/full-display failures can exercise the production capture driver.
source = (root / 'Tests/ProductState/Environment.swift').read_text()
assert 'let capturedAt: Date, fullDisplay = true' in source
assert 'let width = 2, height = 2, sourceWidth = 2, sourceHeight = 2' in source
source = source.replace('let capturedAt: Date, fullDisplay = true', 'let capturedAt: Date\n    var fullDisplay = true')
source = source.replace('let width = 2, height = 2, sourceWidth = 2, sourceHeight = 2', 'var width = 2, height = 2, sourceWidth = 2, sourceHeight = 2')
source = source.replace('let image: UIImage, jpeg = Data()', 'let image: UIImage\n    var jpeg = Data()')
# An actual executor boundary error must not inherit capture predicates from
# an earlier attempt. Keep this hook local to the generated integration fake.
assert source.count('var actionDelay: UInt64 = 0') == 1
source = source.replace('var actionDelay: UInt64 = 0', 'var actionDelay: UInt64 = 0\n    var executeError: Error?\n    var executeCalls = 0')
assert source.count('actions.append(action.kind); dispatched.append(action)') == 1
source = source.replace('actions.append(action.kind); dispatched.append(action)', 'executeCalls += 1\n        if let executeError { throw executeError }\n        actions.append(action.kind); dispatched.append(action)')
assert source.count('var selectedID: String? = \"offline-device\"') == 1
source = source.replace('var selectedID: String? = \"offline-device\"', 'var selectedID: String? = \"offline-device\"\n    var pointerConnectionGeneration = UUID()')
# Workflow leases require actual reference identity and nonempty encoded pixels.
# Keep these changes local: ordinary engine suites still use their original fake.
assert source.count('struct UIImage {') == 1
source = source.replace('import CoreGraphics', 'import CoreGraphics\nimport ImageIO\nimport UniformTypeIdentifiers')
source = source.replace('struct UIImage {', 'final class UIImage {')
needle = '        self.capturedAt = capturedAt; self.captureID = captureID; image = UIImage(shade: shade)'
assert source.count(needle) == 1
source = source.replace(needle, needle + '''
        let bytes = NSMutableData()
        let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image.cgImage!, nil)
        precondition(CGImageDestinationFinalize(destination))
        jpeg = bytes as Data
''')
(tmp / 'Environment.swift').write_text(source)
PY
xcrun swiftc -module-cache-path "$check_dir/module-cache" -parse-as-library \
  "$project_dir/Shared/FrameReadiness.swift" "$project_dir/Shared/RunMetrics.swift" \
  "$project_dir/Shared/PhonePageAdapters.swift" "$project_dir/Shared/XiaohongshuPageAdapter.swift" "$project_dir/Shared/XiaohongshuCollection.swift" \
  "$project_dir/Shared/SystemToolRequest.swift" "$project_dir/Shared/PhoneHarness.swift" \
  "$project_dir/Shared/ComposerAttachment.swift" "$project_dir/Shared/AgentModels.swift" "$project_dir/Shared/MouseProtocol.swift" \
  "$project_dir/Shared/VoiceCommand.swift" "$project_dir/Shared/ModelHistoryContext.swift" \
  "$project_dir/Shared/NativeTaskResult.swift" "$project_dir/Shared/NativePlanningRecovery.swift" "$project_dir/PhoneAgent/Stores/TaskHistoryStore.swift" \
  "$project_dir/PhoneAgent/Stores/XiaohongshuCollectionStore.swift" \
  "$project_dir/PhoneAgent/Services/PrivacyConsent.swift" \
  "$project_dir/PhoneAgent/Services/XiaohongshuCollector.swift" \
  "$project_dir/PhoneAgent/Services/XiaohongshuNavigationDriver.swift" \
  "$project_dir/PhoneAgent/Services/XiaohongshuLinkResolver.swift" \
  "$project_dir/Shared/WorkflowDiagnostics.swift" "$project_dir/PhoneAgent/Stores/WorkflowDiagnosticsStore.swift" \
  "$project_dir/Shared/WeChatContactIdentity.swift" "$project_dir/Shared/ChatEvidence.swift" \
  "$project_dir/Shared/FileTransferWorkflow.swift" "$project_dir/Shared/WeChatFileTransferPages.swift" \
  "$project_dir/PhoneAgent/Stores/FileTransferStore.swift" "$project_dir/PhoneAgent/Services/FileTransferCoordinator.swift" \
  "$project_dir/PhoneAgent/Services/WeChatFileTransferDriver.swift" \
  "$project_dir/PhoneAgent/Services/PhoneWorkflowCaptureDriver.swift" \
  "$check_dir/Environment.swift" "$check_dir/Engine.swift" \
  "$project_dir/Shared/PhoneVisualControls.swift" "$project_dir/PhoneAgent/Services/PhoneRasterEvidence.swift" \
  "$project_dir/Shared/PhoneOverlayClassifier.swift" \
  "$project_dir/PhoneAgent/Services/WorkflowObservationLease.swift" \
  "$project_dir/PhoneAgent/Services/PhoneHarnessRuntime.swift" \
  "$project_dir/Tests/WorkflowIntegration/main.swift" \
  "$project_dir/Tests/WorkflowIntegration/CaptureFailureChecks.swift" \
  "$project_dir/Tests/WorkflowIntegration/ScrollBindingChecks.swift" \
  -o "$check_dir/workflow-integration-checks"
"$check_dir/workflow-integration-checks"
