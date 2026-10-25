#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/sela-understanding.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/ComposerAttachment.swift" "$project_dir/Shared/AssistantConversationContext.swift" \
  "$project_dir/Shared/ConversationUnderstanding.swift" "$project_dir/Tests/AssistantConversation/Environment.swift" \
  "$project_dir/Tests/Understanding/main.swift" -o "$check_dir/checks"
"$check_dir/checks" "$project_dir/Skills/sela-intent/references/evaluation-cases.json"
