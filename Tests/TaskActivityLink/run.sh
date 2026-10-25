#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_root="${PHONE_TEST_SOURCE_ROOT:-$project_dir}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/sela-activity-link.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -module-cache-path "$check_dir/module-cache" "$source_root/Shared/TaskActivityLink.swift" "$source_root/Shared/TaskActivityPresentation.swift" "$project_dir/Tests/TaskActivityLink/main.swift" -o "$check_dir/check"
"$check_dir/check"
