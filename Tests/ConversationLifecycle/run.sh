#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/conversation-lifecycle-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/ComposerAttachment.swift" \
  "$project_dir/Shared/NativeTaskResult.swift" "$project_dir/Shared/AssistantConversationContext.swift" "$project_dir/Shared/ConversationUnderstanding.swift" \
  "$project_dir/PhoneAgent/Stores/AssistantConversationStore.swift" \
  "$project_dir/PhoneAgent/Services/AssistantConversation.swift" \
  "$project_dir/Tests/AssistantConversation/Environment.swift" \
  "$project_dir/Tests/ConversationLifecycle/main.swift" \
  -o "$check_dir/conversation-lifecycle-checks"
"$check_dir/conversation-lifecycle-checks"
