#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ $# -gt 1 ]]; then
  echo "Usage: bash Tests/ComposerAttachments/run.sh [--import-only|--lifecycle-only|--wire-only]" >&2
  exit 2
fi
case "${1:-}" in
  ""|--import-only|--lifecycle-only|--wire-only) ;;
  *) echo "Unknown check selection: $1" >&2; exit 2 ;;
esac
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/composer-attachment-checks.XXXXXX")"
finish() {
  local result=$?
  if [[ "$result" -ne 0 ]]; then
    echo "ComposerAttachments failure evidence preserved: $check_dir" >&2
  else
    rm -rf "$check_dir"
  fi
  exit "$result"
}
trap finish EXIT
if [[ "${1:-}" != "--lifecycle-only" && "${1:-}" != "--wire-only" ]]; then
python3 "$project_dir/Tests/ComposerAttachments/Fixtures.py" "$check_dir/fixtures"

# Compile the actual ImageIO, Vision, PDFKit, Office reader and observable store.
# The small AgentError declaration in ImportChecks supplies only the app error
# boundary; no network/model/photo-picker or iPhone action is simulated as live.
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/ComposerAttachment.swift" \
  "$project_dir/PhoneAgent/Services/ComposerAttachmentImport.swift" \
  "$project_dir/PhoneAgent/Stores/ComposerAttachmentStore.swift" \
  "$project_dir/PhoneAgent/Services/OfficeTextImport.swift" \
  "$project_dir/PhoneAgent/Services/LocalFileRecognition.swift" \
  "$project_dir/Tests/ComposerAttachments/ImportChecks.swift" \
  -lz -o "$check_dir/import-checks"
"$check_dir/import-checks" "$check_dir/fixtures"
fi
if [[ "${1:-}" == "--import-only" ]]; then exit 0; fi

# Keep the current task engine intact except for its iOS image import, as the
# existing ProductState suite does. All model/input boundaries are offline.
if [[ "${1:-}" != "--wire-only" ]]; then
python3 - "$project_dir/PhoneAgent/Services/AgentEngine.swift" "$check_dir/Engine.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
assert source.count('import UIKit') == 1
Path(sys.argv[2]).write_text(source.replace('import UIKit', 'import CoreGraphics'))
PY
python3 - "$project_dir/PhoneAgent/Services/WorkflowObservationLease.swift" "$check_dir/LeaseFailure.swift" <<'PYLEASE'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(); start=s.index('struct WorkflowLeaseFailure:'); end=s.index('/// Pixel recognition reuse only.')
Path(sys.argv[2]).write_text('import Foundation\n'+s[start:end])
PYLEASE
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/ComposerAttachment.swift" "$project_dir/Shared/AssistantConversationContext.swift" "$project_dir/Shared/ConversationUnderstanding.swift" \
  "$project_dir/Shared/FrameReadiness.swift" "$project_dir/Shared/RunMetrics.swift" \
  "$project_dir/Shared/PhonePageAdapters.swift" "$project_dir/Shared/XiaohongshuPageAdapter.swift" \
  "$project_dir/Shared/SystemToolRequest.swift" "$project_dir/Shared/PhoneHarness.swift" \
  "$project_dir/Shared/AgentModels.swift" "$project_dir/Shared/MouseProtocol.swift" \
  "$project_dir/Shared/VoiceCommand.swift" "$project_dir/Shared/ModelHistoryContext.swift" \
  "$project_dir/Shared/NativeTaskResult.swift" "$project_dir/Shared/NativePlanningRecovery.swift" "$project_dir/PhoneAgent/Stores/TaskHistoryStore.swift" "$project_dir/PhoneAgent/Stores/TaskQueueStore.swift" \
  "$project_dir/PhoneAgent/Services/PrivacyConsent.swift" \
  "$project_dir/Tests/ProductState/Environment.swift" "$check_dir/LeaseFailure.swift" "$check_dir/Engine.swift" \
  "$project_dir/Tests/ComposerAttachments/LifecycleChecks.swift" \
  -o "$check_dir/lifecycle-checks"
"$check_dir/lifecycle-checks"
fi
if [[ "${1:-}" == "--lifecycle-only" ]]; then exit 0; fi

# Compile the full current client with its single HTTP load body replaced by a
# local collector. Prompt assembly, validation and response parsing stay real.
python3 - "$project_dir/PhoneAgent/Services/VisionClient.swift" "$check_dir/VisionClient.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
signature = '    private func load(_ request: URLRequest, parentID: UUID? = nil) async throws -> (Data, URLResponse) {'
assert source.count(signature) == 1
start = source.index(signature)
cursor = start + len(signature)
depth = 1
while depth:
    depth += (source[cursor] == '{') - (source[cursor] == '}')
    cursor += 1
replacement = signature + '\n        return try await AttachmentWireProbe.load(request)\n    }'
Path(sys.argv[2]).write_text(source[:start] + replacement + source[cursor:])
PY
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/ComposerAttachment.swift" "$project_dir/Shared/NativeTaskResult.swift" "$project_dir/Shared/AssistantConversationContext.swift" "$project_dir/Shared/ConversationUnderstanding.swift" \
  "$project_dir/Shared/AgentModels.swift" "$project_dir/Shared/MouseProtocol.swift" \
  "$project_dir/Shared/PhoneHarness.swift" "$project_dir/Shared/SystemToolRequest.swift" \
  "$project_dir/Shared/RunMetrics.swift" "$project_dir/Shared/ModelHistoryContext.swift" \
  "$project_dir/Shared/CameraObservationWindow.swift" "$project_dir/Shared/MeetingNotes.swift" \
  "$project_dir/Shared/WebSearchModels.swift" "$project_dir/Shared/WebPageModels.swift" \
  "$project_dir/Shared/WebInvestigationModels.swift" \
  "$project_dir/Shared/NativePlanningRecovery.swift" "$project_dir/Shared/ChatGPTPlanProtocol.swift" "$project_dir/Shared/ChatGPTPlanResponses.swift" \
  "$project_dir/PhoneAgent/Services/ChatGPTPlanRuntime.swift" \
  "$project_dir/PhoneAgent/Services/PrivacyConsent.swift" "$project_dir/PhoneAgent/Services/PhoneAppSkillCatalog.swift" \
  "$project_dir/PhoneAgent/Services/ConnectedConversationClient.swift" "$check_dir/VisionClient.swift" \
  "$project_dir/Tests/ComposerAttachments/WireChecks.swift" \
  -o "$check_dir/wire-checks"
"$check_dir/wire-checks"
