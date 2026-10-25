#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checks_dir="$(mktemp -d "${TMPDIR:-/tmp}/sela-native-planning.XXXXXX")"
trap 'rm -rf "$checks_dir"' EXIT
python3 "$project_dir/Tests/NativePlanningRecovery/wiring.py" "$project_dir"
xcrun swiftc -parse-as-library "$project_dir/Shared/NativePlanningRecovery.swift" \
  "$project_dir/Tests/NativePlanningRecovery/main.swift" -o "$checks_dir/checks"
"$checks_dir/checks"
python3 "$project_dir/Tests/NativePlanningRecovery/extract_load.py" "$project_dir" "$checks_dir/Load.swift"
xcrun swiftc -parse-as-library "$project_dir/Shared/NativePlanningRecovery.swift" \
  "$project_dir/Shared/ChatGPTPlanProtocol.swift" "$project_dir/Shared/ChatGPTPlanResponses.swift" \
  "$checks_dir/Load.swift" "$project_dir/Tests/NativePlanningRecovery/load_boundary.swift" -o "$checks_dir/producer"
"$checks_dir/producer"
