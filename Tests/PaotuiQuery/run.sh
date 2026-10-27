#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/sela-paotui-query.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
# Compile unchanged production model files, including their actual error/model
# dependencies. No extracted source, rewritten imports or replacement data types.
swiftc -parse-as-library \
  "$project_dir/Shared/AgentModels.swift" \
  "$project_dir/Shared/SystemToolRequest.swift" \
  "$project_dir/Shared/PhoneHarness.swift" \
  "$project_dir/PhoneAgent/Models/MeituanPaotui.swift" \
  "$project_dir/PhoneAgent/Models/PaotuiQueryResult.swift" \
  "$project_dir/Tests/PaotuiQuery/main.swift" \
  -o "$test_dir/checks"
"$test_dir/checks"
