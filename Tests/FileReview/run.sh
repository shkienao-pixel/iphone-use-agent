#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/file-review.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
 "$project_dir/Shared/PhoneHarness.swift" "$project_dir/Shared/WorkflowDiagnostics.swift" \
 "$project_dir/PhoneAgent/Stores/WorkflowDiagnosticsStore.swift" "$project_dir/PhoneAgent/Services/FileTransferReviewDiagnostics.swift" \
 "$project_dir/Shared/FileTransferWorkflow.swift" "$project_dir/Shared/FileTransferReview.swift" \
 "$project_dir/PhoneAgent/Stores/FileTransferStore.swift" "$project_dir/PhoneAgent/Services/FileTransferCoordinator.swift" \
 "$project_dir/Tests/FileReview/main.swift" -o "$check_dir/checks"
"$check_dir/checks"
