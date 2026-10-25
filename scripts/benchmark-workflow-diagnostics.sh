#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/workflow-diagnostics-benchmark.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
store_source="${1:-$project_dir/PhoneAgent/Stores/WorkflowDiagnosticsStore.swift}"
xcrun swiftc -O -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/PhoneHarness.swift" \
  "$project_dir/Shared/WorkflowDiagnostics.swift" \
  "$store_source" \
  "$project_dir/Tools/WorkflowDiagnosticsBenchmark.swift" \
  -o "$check_dir/workflow-diagnostics-benchmark"
"$check_dir/workflow-diagnostics-benchmark"
