#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/sela-paotui-connection.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -parse-as-library \
  "$project_dir/Shared/SystemToolRequest.swift" \
  "$project_dir/Shared/PhoneHarness.swift" \
  "$project_dir/Shared/AgentModels.swift" \
  "$project_dir/PhoneAgent/Models/MeituanPaotui.swift" \
  "$project_dir/PhoneAgent/Services/PaotuiDependencies.swift" \
  "$project_dir/PhoneAgent/Services/PaotuiConnection.swift" \
  "$project_dir/PhoneAgent/Services/PaotuiHTTPTransport.swift" \
  "$project_dir/PhoneAgent/Services/MeituanPaotuiAuthorization.swift" \
  "$project_dir/PhoneAgent/Services/MeituanPaotuiClient.swift" \
  "$project_dir/Tests/PaotuiConnection/main.swift" \
  -o "$test_dir/checks"
"$test_dir/checks"
