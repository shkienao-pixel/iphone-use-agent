#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/sela-paotui.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library "$project_dir/Shared/SystemToolRequest.swift" "$project_dir/PhoneAgent/Models/MeituanPaotui.swift" "$project_dir/PhoneAgent/Services/MeituanPaotuiClient.swift" "$project_dir/Tests/Paotui/main.swift" -o "$test_dir/checks"
"$test_dir/checks"
sed '/^import UIKit$/d' "$project_dir/PhoneAgent/Services/MeituanPaotuiStore.swift" > "$test_dir/ProductionPaotuiStore.swift"
swiftc -parse-as-library "$project_dir/PhoneAgent/Models/MeituanPaotui.swift" "$project_dir/PhoneAgent/Services/MeituanPaotuiClient.swift" "$test_dir/ProductionPaotuiStore.swift" "$project_dir/Tests/Paotui/store.swift" -o "$test_dir/store-checks"
"$test_dir/store-checks"
swiftc -parse-as-library "$project_dir/PhoneAgent/Models/MeituanPaotui.swift" "$project_dir/PhoneAgent/Services/MeituanPaotuiClient.swift" "$project_dir/PhoneAgent/Services/MeituanPaotuiAuthorization.swift" "$project_dir/Tests/Paotui/authorization.swift" -o "$test_dir/authorization-checks"
"$test_dir/authorization-checks"
