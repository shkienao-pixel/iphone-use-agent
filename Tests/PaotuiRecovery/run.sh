#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/sela-paotui-recovery.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
sources=(
  Shared/AgentModels.swift Shared/SystemToolRequest.swift Shared/PhoneHarness.swift
  Shared/ComposerAttachment.swift Shared/NativeTaskResult.swift Shared/AssistantConversationContext.swift Shared/ConversationUnderstanding.swift
  PhoneAgent/Models/MeituanPaotui.swift PhoneAgent/Models/PaotuiQueryResult.swift PhoneAgent/Models/PaotuiSessionSummary.swift
  PhoneAgent/Services/PaotuiSession.swift PhoneAgent/Services/PaotuiDependencies.swift PhoneAgent/Services/PaotuiHTTPTransport.swift
  PhoneAgent/Services/MeituanPaotuiAuthorization.swift PhoneAgent/Services/PaotuiConnection.swift PhoneAgent/Services/MeituanPaotuiClient.swift
  PhoneAgent/Services/PaotuiOrderJournal.swift PhoneAgent/Services/PaotuiOrderService.swift PhoneAgent/Services/MeituanPaotuiStore.swift
  PhoneAgent/Services/PaotuiCardProjector.swift PhoneAgent/Services/MeituanPaotuiConversation.swift PhoneAgent/Services/PaotuiModule.swift
  PhoneAgent/Services/PaotuiPreparationRepository.swift PhoneAgent/Services/PaotuiDiagnostics.swift
  Tests/PaotuiSupport/Fixtures.swift Tests/PaotuiConversation/Environment.swift Tests/PaotuiRecovery/main.swift
)
if [[ -f "$project_dir/PhoneAgent/Services/PaotuiInterpretationPatch.swift" ]]; then sources+=(PhoneAgent/Services/PaotuiInterpretationPatch.swift); fi
arguments=()
for source in "${sources[@]}"; do arguments+=("$project_dir/$source"); done
swiftc -parse-as-library "${arguments[@]}" -o "$test_dir/module"
"$test_dir/module"
