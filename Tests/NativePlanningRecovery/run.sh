#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checks_dir="$(mktemp -d "${TMPDIR:-/tmp}/sela-native-planning.XXXXXX")"
trap 'rm -rf "$checks_dir"' EXIT
python3 "$project_dir/Tests/NativePlanningRecovery/wiring.py" "$project_dir"
xcrun swiftc -parse-as-library "$project_dir/Shared/NativePlanningRecovery.swift" \
  "$project_dir/Tests/NativePlanningRecovery/main.swift" -o "$checks_dir/checks"
"$checks_dir/checks"
