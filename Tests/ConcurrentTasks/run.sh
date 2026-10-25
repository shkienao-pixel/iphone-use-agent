#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/phone-concurrent-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT

# Keep the production engine intact except for the platform image import.
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
python3 "$project_dir/Tests/ConcurrentTasks/ExtractApproval.py" "$project_dir/PhoneAgent/Services/SystemTools.swift" "$check_dir/ApprovalBoundary.swift"
xcrun swiftc -module-cache-path "$check_dir/module-cache" -parse-as-library \
  "$project_dir/Shared/FrameReadiness.swift" "$project_dir/Shared/RunMetrics.swift" \
  "$project_dir/Shared/PhonePageAdapters.swift" "$project_dir/Shared/XiaohongshuPageAdapter.swift" \
  "$project_dir/Shared/SystemToolRequest.swift" \
  "$project_dir/Shared/PhoneHarness.swift" "$project_dir/Shared/ComposerAttachment.swift" "$project_dir/Shared/AgentModels.swift" \
  "$project_dir/Shared/MouseProtocol.swift" \
  "$project_dir/Shared/VoiceCommand.swift" \
  "$project_dir/Shared/ModelHistoryContext.swift" \
  "$project_dir/PhoneAgent/Stores/TaskQueueStore.swift" \
  "$project_dir/Shared/NativeTaskResult.swift" "$project_dir/Shared/NativePlanningRecovery.swift" "$project_dir/PhoneAgent/Stores/TaskHistoryStore.swift" \
  "$project_dir/PhoneAgent/Services/PrivacyConsent.swift" \
  "$project_dir/Tests/ProductState/Environment.swift" \
  "$check_dir/LeaseFailure.swift" "$check_dir/Engine.swift" \
  "$project_dir/PhoneAgent/Services/BackgroundTaskCoordinator.swift" \
  "$project_dir/PhoneAgent/Services/TaskResourceGate.swift" \
  "$project_dir/PhoneAgent/Services/BackgroundToolPolicy.swift" \
  "$project_dir/Tests/ConcurrentTasks/PermissionEnvironment.swift" "$check_dir/ApprovalBoundary.swift" \
  "$project_dir/Tests/ConcurrentTasks/main.swift" \
  -o "$check_dir/phone-concurrent-checks"
"$check_dir/phone-concurrent-checks"
