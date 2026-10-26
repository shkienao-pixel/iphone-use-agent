#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/phone-completion-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
python3 - "$project_dir" "$check_dir" <<'PY'
from pathlib import Path
import sys
root,out=map(Path,sys.argv[1:])
s=(root/'PhoneAgent/Services/AgentEngine.swift').read_text()
assert s.count('import UIKit')==1
(out/'Engine.swift').write_text(s.replace('import UIKit','import CoreGraphics'))
s=(root/'PhoneAgent/Services/WorkflowObservationLease.swift').read_text()
(out/'LeaseFailure.swift').write_text('import Foundation\n'+s[s.index('struct WorkflowLeaseFailure:'):s.index('/// Pixel recognition reuse only.')])
PY
xcrun swiftc -module-cache-path "$check_dir/module-cache" -parse-as-library \
  "$project_dir/Shared/FrameReadiness.swift" "$project_dir/Shared/RunMetrics.swift" \
  "$project_dir/Shared/PhonePageAdapters.swift" "$project_dir/Shared/XiaohongshuPageAdapter.swift" \
  "$project_dir/Shared/SystemToolRequest.swift" "$project_dir/Shared/PhoneHarness.swift" \
  "$project_dir/Shared/ComposerAttachment.swift" "$project_dir/Shared/AgentModels.swift" \
  "$project_dir/Shared/MouseProtocol.swift" "$project_dir/Shared/VoiceCommand.swift" \
  "$project_dir/Shared/ModelHistoryContext.swift" "$project_dir/PhoneAgent/Stores/TaskQueueStore.swift" \
  "$project_dir/Shared/NativeTaskResult.swift" "$project_dir/Shared/NativePlanningRecovery.swift" \
  "$project_dir/PhoneAgent/Stores/TaskHistoryStore.swift" "$project_dir/PhoneAgent/Services/PrivacyConsent.swift" \
  "$project_dir/Tests/ProductState/Environment.swift" "$check_dir/LeaseFailure.swift" "$check_dir/Engine.swift" \
  "$project_dir/Tests/TaskCompletion/main.swift" -o "$check_dir/checks"
"$check_dir/checks"
