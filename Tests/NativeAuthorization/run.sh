#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/native-authorization-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/NativeAuthorizationGate.swift" "$project_dir/Shared/NativeForegroundGate.swift" \
  "$project_dir/Tests/NativeAuthorization/main.swift" -o "$check_dir/checks"
"$check_dir/checks"
