#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checks_dir="$(mktemp -d "${TMPDIR:-/tmp}/sela-native-results.XXXXXX")"
trap 'rm -rf "$checks_dir"' EXIT
xcrun swiftc -parse-as-library "$project_dir/Shared/NativeTaskResult.swift" "$project_dir/Tests/NativeTaskResults/main.swift" -o "$checks_dir/checks"
TZ=Asia/Shanghai "$checks_dir/checks"
python3 "$project_dir/Tests/NativeTaskResults/event_write_wiring.py"
