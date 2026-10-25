#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checks_dir="$(mktemp -d "${TMPDIR:-/tmp}/native-alarm-cleanup.XXXXXX")"
trap 'rm -rf "$checks_dir"' EXIT
python3 "$project_dir/Tests/NativeAlarmFixtureCleanup/extract.py" "$project_dir/PhoneAgent/Services/SystemTools.swift" "$checks_dir/Production.swift"
xcrun swiftc -parse-as-library "$checks_dir/Production.swift" "$project_dir/Tests/NativeAlarmFixtureCleanup/main.swift" -o "$checks_dir/checks"
"$checks_dir/checks"
