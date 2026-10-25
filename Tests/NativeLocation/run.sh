#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/native-location-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
python3 - "$project_dir/PhoneAgent/Services/NativeSystemTools.swift" "$check_dir/LocationReader.swift" <<'PY'
import pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text();start=s.index('@MainActor\nprivate final class NativeLocationReader:')
s=s[start:].replace('private final class NativeLocationReader:','final class NativeLocationReader:',1)
assert s.count('.seconds(30)')==1
# Preserve the actual reader/control flow; only shorten its acquisition deadline.
s=s.replace('.seconds(30)','.milliseconds(80)')
pathlib.Path(sys.argv[2]).write_text('import Foundation\n'+s)
PY
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/NativeToolData.swift" "$project_dir/Tests/NativeLocation/Environment.swift" \
  "$check_dir/LocationReader.swift" "$project_dir/Tests/NativeLocation/main.swift" -o "$check_dir/checks"
"$check_dir/checks"
