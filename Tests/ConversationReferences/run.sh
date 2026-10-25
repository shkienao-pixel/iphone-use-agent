#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_root="${PHONE_TEST_SOURCE_ROOT:-$project_dir}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/conversation-reference-checks.XXXXXX")"
finish() {
  local result=$?
  if [[ "$result" -ne 0 ]]; then
    echo "ConversationReferences failure evidence preserved: $check_dir" >&2
  else
    rm -rf "$check_dir"
  fi
  exit "$result"
}
trap finish EXIT
python3 "$project_dir/Tests/ConversationReferences/ExtractContext.py" "$source_root" "$project_dir/Tests/ConversationReferences/Environment.swift" "$check_dir/context"
python3 "$project_dir/Tests/ConversationRouting/ExtractProduction.py" "$source_root" "$check_dir/clients"
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$source_root/Shared/ComposerAttachment.swift" "$source_root/Shared/AssistantConversationContext.swift" "$source_root/Shared/ConversationUnderstanding.swift" \
  "$source_root/Shared/AgentModels.swift" "$source_root/Shared/MouseProtocol.swift" \
  "$source_root/Shared/ChatGPTPlanProtocol.swift" "$source_root/Shared/ChatGPTPlanResponses.swift" \
  "$source_root/PhoneAgent/Services/ChatGPTPlanRuntime.swift" \
  "$source_root/Shared/PhoneHarness.swift" "$source_root/Shared/SystemToolRequest.swift" \
  "$source_root/Shared/RunMetrics.swift" "$source_root/Shared/ModelHistoryContext.swift" \
  "$source_root/Shared/CameraObservationWindow.swift" "$source_root/Shared/MeetingNotes.swift" \
  "$source_root/Shared/WebSearchModels.swift" "$source_root/Shared/WebPageModels.swift" \
  "$source_root/Shared/WebInvestigationModels.swift" "$source_root/PhoneAgent/Services/PrivacyConsent.swift" \
  "$source_root/PhoneAgent/Services/UnifiedConversationRouter.swift" \
  "$source_root/PhoneAgent/Services/ConversationIntentSkill.swift" \
  "$source_root/PhoneAgent/Services/CtripClient.swift" "$source_root/PhoneAgent/Stores/AssistantConversationStore.swift" \
  "$source_root/PhoneAgent/Services/PhoneAppSkillCatalog.swift" \
  "$check_dir/clients/VisionClient.swift" "$check_dir/clients/ConnectedConversationClient.swift" \
  "$project_dir/Tests/ConversationRouting/Environment.swift" "$check_dir/context/ReferenceEnvironment.swift" \
  "$project_dir/Tests/ConversationReferences/main.swift" -o "$check_dir/conversation-references"
mkdir -p "$check_dir/Skills"
cp -R "$source_root/Skills/sela-intent" "$check_dir/Skills/"
"$check_dir/conversation-references" "$check_dir/result.json" "$check_dir"
