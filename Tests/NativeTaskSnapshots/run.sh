#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/native-snapshot-checks.XXXXXX")"
trap 'snapshot_check_status=$?; rm -rf "$check_dir"; exit "$snapshot_check_status"' EXIT
python3 "$project_dir/Tests/NativeTaskSnapshots/prepare_boundary.py" "$project_dir" "$check_dir/Environment.swift"
snapshot_sources=("$project_dir/Shared/AssistantConversationContext.swift")
if [[ -f "$project_dir/Shared/ConversationUnderstanding.swift" ]]; then
  snapshot_sources+=("$project_dir/Shared/ConversationUnderstanding.swift")
fi
xcrun swiftc -D DEBUG -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/ComposerAttachment.swift" "$project_dir/Shared/NativeTaskResult.swift" \
  "${snapshot_sources[@]}" \
  "$project_dir/PhoneAgent/Stores/AssistantConversationStore.swift" "$project_dir/PhoneAgent/Stores/TaskHistoryStore.swift" \
  "$project_dir/PhoneAgent/Services/AssistantConversation.swift" "$check_dir/Environment.swift" \
  "$project_dir/Tests/NativeTaskSnapshots/main.swift" -o "$check_dir/checks"
"$check_dir/checks"
python3 "$project_dir/Tests/NativeTaskSnapshots/wiring.py"
