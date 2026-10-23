#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/phone-harness-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT

xcrun swiftc -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/SystemToolRequest.swift" \
  "$project_dir/Shared/AgentModels.swift" \
  "$project_dir/Shared/MouseProtocol.swift" \
  "$project_dir/Shared/PhoneHarness.swift" \
  "$project_dir/Tests/Harness/main.swift" \
  -o "$check_dir/harness-checks"
"$check_dir/harness-checks"
