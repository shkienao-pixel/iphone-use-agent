#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/task-history-persistence.XXXXXX")"
trap 'result=$?; rm -rf "$check_dir"; exit "$result"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/ComposerAttachment.swift" \
  "$project_dir/Shared/NativeTaskResult.swift" \
  "$project_dir/PhoneAgent/Stores/TaskHistoryStore.swift" \
  "$project_dir/Tests/TaskHistoryPersistence/Environment.swift" \
  "$project_dir/Tests/TaskHistoryPersistence/main.swift" \
  -o "$check_dir/checks"
"$check_dir/checks"
