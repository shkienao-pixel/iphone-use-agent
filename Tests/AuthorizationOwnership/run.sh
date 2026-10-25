#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/authorization-ownership-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$project_dir/PhoneAgent/Services/OfficeAuthorizationModels.swift" \
  "$project_dir/PhoneAgent/Services/OfficeAuthorizationPolicy.swift" \
  "$project_dir/PhoneAgent/Services/OfficeAuthorizationFlow.swift" \
  "$project_dir/Tests/AuthorizationOwnership/main.swift" \
  -o "$check_dir/authorization-ownership-checks"
"$check_dir/authorization-ownership-checks"
