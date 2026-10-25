#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_root="${PHONE_TEST_SOURCE_ROOT:-$project_dir}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/conversation-control-checks.XXXXXX")"
finish() {
  local result=$?
  if [[ "$result" -ne 0 ]]; then
    echo "ConversationControls failure evidence preserved: $check_dir" >&2
  else
    rm -rf "$check_dir"
  fi
  exit "$result"
}
trap finish EXIT
python3 "$project_dir/Tests/ConversationControls/ExtractProduction.py" "$source_root" "$project_dir/Tests/ConversationControls" "$check_dir/production"
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$source_root/Shared/ComposerAttachment.swift" "$source_root/Shared/NativeTaskResult.swift" "$source_root/Shared/AssistantConversationContext.swift" "$source_root/Shared/ConversationUnderstanding.swift" \
  "$check_dir/production/Environment.swift" "$project_dir/Tests/ConversationControls/main.swift" \
  -o "$check_dir/conversation-controls"
"$check_dir/conversation-controls" "$check_dir/result.json"
