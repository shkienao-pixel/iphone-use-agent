#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/xiaohongshu-link-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/PhoneHarness.swift" \
  "$project_dir/Shared/PhonePageAdapters.swift" \
  "$project_dir/Shared/XiaohongshuPageAdapter.swift" \
  "$project_dir/Shared/XiaohongshuCollection.swift" \
  "$project_dir/PhoneAgent/Services/XiaohongshuLinkResolver.swift" \
  "$project_dir/Tests/XiaohongshuLinks/main.swift" -o "$check_dir/checks"
"$check_dir/checks"
