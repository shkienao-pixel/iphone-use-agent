#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/native-collection-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/SystemToolRequest.swift" "$project_dir/Shared/NativeCollectionTarget.swift" \
  "$project_dir/Shared/PhoneHarness.swift" "$project_dir/Shared/AgentModels.swift" \
  "$project_dir/Tests/NativeCollections/main.swift" -o "$check_dir/checks"
"$check_dir/checks"
