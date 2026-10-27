#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/sela-paotui-chat.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
shared_sources=("$project_dir/Shared/AgentModels.swift" "$project_dir/Shared/SystemToolRequest.swift" "$project_dir/Shared/PhoneHarness.swift" "$project_dir/Shared/ComposerAttachment.swift" "$project_dir/Shared/NativeTaskResult.swift" "$project_dir/Shared/AssistantConversationContext.swift" "$project_dir/Shared/ConversationUnderstanding.swift")
paotui_sources=("$project_dir/PhoneAgent/Models/MeituanPaotui.swift" "$project_dir/PhoneAgent/Models/PaotuiQueryResult.swift" "$project_dir/PhoneAgent/Services/PaotuiSession.swift" "$project_dir/PhoneAgent/Services/PaotuiPreparationRepository.swift" "$project_dir/PhoneAgent/Services/PaotuiDiagnostics.swift" "$project_dir/PhoneAgent/Models/PaotuiSessionSummary.swift" "$project_dir/PhoneAgent/Services/PaotuiCardProjector.swift" "$project_dir/PhoneAgent/Services/PaotuiInterpretationPatch.swift" "$project_dir/PhoneAgent/Services/PaotuiDependencies.swift" "$project_dir/PhoneAgent/Services/PaotuiHTTPTransport.swift" "$project_dir/PhoneAgent/Services/MeituanPaotuiAuthorization.swift" "$project_dir/PhoneAgent/Services/PaotuiConnection.swift" "$project_dir/PhoneAgent/Services/MeituanPaotuiClient.swift" "$project_dir/PhoneAgent/Services/PaotuiOrderJournal.swift" "$project_dir/PhoneAgent/Services/PaotuiOrderService.swift" "$project_dir/PhoneAgent/Services/MeituanPaotuiStore.swift" "$project_dir/PhoneAgent/Services/MeituanPaotuiConversation.swift")
for scenario in main refinements concurrency lifecycle dependencies canonical references patch; do
    swiftc -parse-as-library "${shared_sources[@]}" "${paotui_sources[@]}" "$project_dir/Tests/PaotuiSupport/Fixtures.swift" "$project_dir/Tests/PaotuiConversation/Environment.swift" "$project_dir/Tests/PaotuiConversation/$scenario.swift" -o "$test_dir/$scenario"
    "$test_dir/$scenario"
done
swiftc -parse-as-library "$project_dir/Shared/ComposerAttachment.swift" "$project_dir/Shared/NativeTaskResult.swift" "$project_dir/Shared/AssistantConversationContext.swift" "$project_dir/Shared/ConversationUnderstanding.swift" "$project_dir/PhoneAgent/Stores/AssistantConversationStore.swift" "$project_dir/PhoneAgent/Services/DidiChatSimulationRegistry.swift" "$project_dir/PhoneAgent/Services/AssistantConversation.swift" "$project_dir/Tests/AssistantConversation/Environment.swift" "$project_dir/Tests/PaotuiConversation/host.swift" -o "$test_dir/host-checks"
"$test_dir/host-checks"
