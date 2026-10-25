#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/ctrip-client-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/SystemToolRequest.swift" \
  "$project_dir/PhoneAgent/Services/CtripClient.swift" \
  "$project_dir/PhoneAgent/Stores/CtripStore.swift" \
  "$project_dir/Tests/CtripClient/main.swift" -o "$check_dir/checks"
"$check_dir/checks"
