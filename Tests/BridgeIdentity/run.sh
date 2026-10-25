#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_root="${PHONE_TEST_SOURCE_ROOT:-$project_dir}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/bridge-identity-checks.XXXXXX")"
finish() {
  local result=$?
  if [[ "$result" -ne 0 ]]; then
    echo "BridgeIdentity failure evidence preserved: $check_dir" >&2
  else
    rm -rf "$check_dir"
  fi
  exit "$result"
}
trap finish EXIT
python3 "$project_dir/Tests/BridgeIdentity/ExtractProduction.py" "$source_root" "$check_dir/production"
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$source_root/PhoneAgent/Services/OfficeAuthorizationModels.swift" \
  "$source_root/PhoneAgent/Services/OfficeAuthorizationPolicy.swift" \
  "$check_dir/production/Coordinator.swift" \
  "$project_dir/Tests/BridgeIdentity/Environment.swift" \
  "$project_dir/Tests/BridgeIdentity/main.swift" \
  -o "$check_dir/bridge-identity-checks"
"$check_dir/bridge-identity-checks" "$check_dir/result.json"
