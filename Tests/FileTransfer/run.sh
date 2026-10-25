#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/file-transfer-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/FileTransferWorkflow.swift" \
  "$project_dir/PhoneAgent/Stores/FileTransferStore.swift" \
  "$project_dir/PhoneAgent/Services/FileTransferCoordinator.swift" \
  "$project_dir/Tests/FileTransfer/main.swift" -o "$check_dir/file-transfer-checks"
"$check_dir/file-transfer-checks"
