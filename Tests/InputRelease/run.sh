#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/input-release-checks.XXXXXX")"
cleanup() {
  if [[ -n "${INPUT_RELEASE_EVIDENCE_DIR:-}" ]]; then
    mkdir -p "$INPUT_RELEASE_EVIDENCE_DIR"
    for name in results.json input-hashes.json; do
      if [[ -f "$check_dir/$name" ]]; then cp "$check_dir/$name" "$INPUT_RELEASE_EVIDENCE_DIR/"; fi
    done
  fi
  rm -rf "$check_dir"
}
trap cleanup EXIT
python3 "$project_dir/Tests/InputRelease/ExtractProduction.py" "$check_dir"
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/InputReleaseController.swift" \
  "$project_dir/Shared/AgentModels.swift" \
  "$project_dir/Shared/MouseProtocol.swift" \
  "$project_dir/PhoneAgent/Services/HIDKeyboard.swift" \
  "$project_dir/PhoneAgent/Services/MouseExecutor.swift" \
  "$check_dir/Environment.swift" "$project_dir/Tests/InputRelease/ScrollChecks.swift" "$project_dir/Tests/InputRelease/main.swift" -o "$check_dir/checks"
"$check_dir/checks" "$check_dir/results.json"
