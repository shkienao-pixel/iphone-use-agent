#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_root="${PHONE_TEST_SOURCE_ROOT:-$project_dir}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/flight-presentation-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$source_root/Shared/ComposerAttachment.swift" \
  "$source_root/Shared/NativeTaskResult.swift" "$source_root/Shared/AssistantConversationContext.swift" "$source_root/Shared/ConversationUnderstanding.swift" \
  "$project_dir/Tests/FlightPresentation/main.swift" -o "$check_dir/checks"
"$check_dir/checks" "$@"
