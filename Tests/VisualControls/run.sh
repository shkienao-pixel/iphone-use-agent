#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/visual-controls.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -module-cache-path "$check_dir/module-cache" "$project_dir/Shared/PhoneHarness.swift" \
 "$project_dir/Shared/PhoneVisualControls.swift" "$project_dir/PhoneAgent/Services/PhoneRasterEvidence.swift" \
 "$project_dir/Tests/VisualControls/main.swift" -o "$check_dir/checks"
"$check_dir/checks"
