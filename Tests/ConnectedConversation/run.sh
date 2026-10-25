#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/sela-connected.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/cache" \
 "$project_dir/PhoneAgent/Services/ConnectedConversationClient.swift" \
 "$project_dir/PhoneAgent/Services/MeituanMCPClient.swift" \
 "$project_dir/PhoneAgent/Services/MeituanTravelClient.swift" \
 "$project_dir/Shared/SystemToolRequest.swift" \
 "$project_dir/Tests/ConnectedConversation/main.swift" -o "$check_dir/check"
"$check_dir/check"
