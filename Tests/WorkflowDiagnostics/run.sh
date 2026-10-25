#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/workflow-diagnostics-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/PhoneHarness.swift" \
  "$project_dir/Shared/WorkflowDiagnostics.swift" \
  "$project_dir/PhoneAgent/Stores/WorkflowDiagnosticsStore.swift" \
  "$project_dir/Tests/WorkflowDiagnostics/main.swift" \
  -o "$check_dir/workflow-diagnostics-checks"
"$check_dir/workflow-diagnostics-checks"
