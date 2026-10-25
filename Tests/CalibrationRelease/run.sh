#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/calibration-release-checks.XXXXXX")"
cleanup() {
 if [[ -n "${CALIBRATION_RELEASE_EVIDENCE_DIR:-}" ]]; then
  mkdir -p "$CALIBRATION_RELEASE_EVIDENCE_DIR"
  for name in results.json source-hashes.json CalibrationModel.swift Environment.swift; do
   if [[ -f "$check_dir/$name" ]]; then cp "$check_dir/$name" "$CALIBRATION_RELEASE_EVIDENCE_DIR/"; fi
  done
 fi
 rm -rf "$check_dir"
}
trap cleanup EXIT
python3 "$project_dir/Tests/CalibrationRelease/ExtractProduction.py" "$check_dir"
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
 "$project_dir/Shared/InputReleaseController.swift" "$project_dir/Shared/AgentModels.swift" "$project_dir/Shared/MouseProtocol.swift" \
 "$check_dir/Environment.swift" "$check_dir/CalibrationModel.swift" \
 "$project_dir/Tests/CalibrationRelease/main.swift" -o "$check_dir/checks"
"$check_dir/checks" "$check_dir/results.json" "${CALIBRATION_RELEASE_MODE:-after}"
