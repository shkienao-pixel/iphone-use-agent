#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ $# -gt 1 ]]; then
  echo "Usage: bash Tests/ModelHistory/run.sh [path/to/replay-fixture.json]" >&2
  exit 2
fi
fixture_path="${1:-$project_dir/Tests/ModelHistory/fixtures/simulated-notes-history.json}"
if [[ ! -f "$fixture_path" ]]; then
  echo "Model history replay fixture does not exist: $fixture_path" >&2
  exit 2
fi
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/phone-model-history-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT

xcrun swiftc -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/SystemToolRequest.swift" \
  "$project_dir/Shared/AgentModels.swift" \
  "$project_dir/Shared/MouseProtocol.swift" \
  "$project_dir/Shared/PhoneHarness.swift" \
  "$project_dir/Shared/ModelHistoryContext.swift" \
  "$project_dir/Tests/ModelHistory/main.swift" \
  -o "$check_dir/model-history-checks"
"$check_dir/model-history-checks" "$fixture_path"
