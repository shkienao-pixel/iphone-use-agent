#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/phone-content-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/SystemToolRequest.swift" \
  "$project_dir/Shared/AgentModels.swift" \
  "$project_dir/Shared/MouseProtocol.swift" \
  "$project_dir/Shared/PhoneHarness.swift" \
  "$project_dir/Shared/PhoneContentArtifacts.swift" \
  "$project_dir/PhoneAgent/Stores/PhoneContentStore.swift" \
  "$project_dir/PhoneAgent/Services/NativeContentEvidence.swift" \
  "$project_dir/Tests/PhoneContent/main.swift" \
  -o "$check_dir/phone-content-checks"
"$check_dir/phone-content-checks"
