#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/receipt-maintenance.XXXXXX")"
trap 'result=$?; rm -rf "$check_dir"; exit "$result"' EXIT
python3 "$project_dir/Tests/ReceiptMaintenance/extract.py" "$project_dir" "$check_dir/Production.swift"
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/ToolReceiptMaintenance.swift" "$check_dir/Production.swift" \
  "$project_dir/Tests/ReceiptMaintenance/main.swift" -o "$check_dir/checks"
"$check_dir/checks"
