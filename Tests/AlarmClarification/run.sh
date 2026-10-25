#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_root="${PHONE_TEST_SOURCE_ROOT:-$project_dir}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/alarm-clarification-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
python3 - "$source_root" "$check_dir" <<'PY'
from pathlib import Path
import sys
source=Path(sys.argv[1])/'PhoneAgent/Services/UnifiedConversationRouter.swift'
s=source.read_text();start=s.index('enum AlarmClarificationContinuation {')
(Path(sys.argv[2])/'Bridge.swift').write_text('import Foundation\n'+s[start:])
PY
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$source_root/Shared/ComposerAttachment.swift" "$source_root/Shared/NativeTaskResult.swift" "$source_root/Shared/AssistantConversationContext.swift" "$source_root/Shared/ConversationUnderstanding.swift" \
  "$check_dir/Bridge.swift" "$project_dir/Tests/AlarmClarification/main.swift" -o "$check_dir/checks"
"$check_dir/checks" "$project_dir/Tests/AlarmClarification/cases.json" "${1:-$check_dir/result.json}"
