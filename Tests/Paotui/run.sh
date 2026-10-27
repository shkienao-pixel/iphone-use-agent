#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/sela-paotui.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
shared_sources=("$project_dir/Shared/AgentModels.swift" "$project_dir/Shared/SystemToolRequest.swift" "$project_dir/Shared/PhoneHarness.swift" "$project_dir/Shared/ComposerAttachment.swift" "$project_dir/Shared/NativeTaskResult.swift" "$project_dir/Shared/AssistantConversationContext.swift" "$project_dir/Shared/ConversationUnderstanding.swift")
paotui_sources=("$project_dir/PhoneAgent/Models/MeituanPaotui.swift" "$project_dir/PhoneAgent/Services/PaotuiDependencies.swift" "$project_dir/PhoneAgent/Services/PaotuiDiagnostics.swift" "$project_dir/PhoneAgent/Services/PaotuiHTTPTransport.swift" "$project_dir/PhoneAgent/Services/MeituanPaotuiAuthorization.swift" "$project_dir/PhoneAgent/Services/PaotuiConnection.swift" "$project_dir/PhoneAgent/Services/MeituanPaotuiClient.swift")
swiftc -parse-as-library "${shared_sources[@]}" "${paotui_sources[@]}" "$project_dir/Tests/Paotui/main.swift" -o "$test_dir/checks"
"$test_dir/checks"
swiftc -parse-as-library "${shared_sources[@]}" "${paotui_sources[@]}" "$project_dir/PhoneAgent/Services/PaotuiOrderJournal.swift" "$project_dir/PhoneAgent/Services/PaotuiOrderService.swift" "$project_dir/PhoneAgent/Models/PaotuiQueryResult.swift" "$project_dir/PhoneAgent/Services/PaotuiSession.swift" "$project_dir/PhoneAgent/Services/PaotuiPreparationRepository.swift" "$project_dir/PhoneAgent/Services/MeituanPaotuiStore.swift" "$project_dir/Tests/PaotuiSupport/Fixtures.swift" "$project_dir/Tests/Paotui/store.swift" -o "$test_dir/store-checks"
"$test_dir/store-checks"
swiftc -parse-as-library "${shared_sources[@]}" "${paotui_sources[@]}" "$project_dir/Tests/Paotui/authorization.swift" -o "$test_dir/authorization-checks"
"$test_dir/authorization-checks"
