#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_root="${PHONE_TEST_SOURCE_ROOT:-$project_dir}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/pdf-preflight-checks.XXXXXX")"
finish() {
  local result=$?
  # Compiler modules are reproducible; keep failure evidence without its cache.
  rm -rf "$check_dir/module-cache"
  if [[ "$result" -ne 0 ]]; then
    echo "PDFPreflight failure evidence preserved: $check_dir" >&2
  else
    rm -rf "$check_dir"
  fi
  exit "$result"
}
trap finish EXIT
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$source_root/Shared/ComposerAttachment.swift" \
  "$source_root/PhoneAgent/Services/ComposerAttachmentImport.swift" \
  "$source_root/PhoneAgent/Services/OfficeTextImport.swift" \
  "$project_dir/Tests/PDFPreflight/main.swift" \
  -lz -o "$check_dir/pdf-preflight-checks"
"$check_dir/pdf-preflight-checks" "$check_dir/fixtures"
