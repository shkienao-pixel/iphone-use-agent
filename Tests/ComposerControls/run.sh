#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_root="${PHONE_TEST_SOURCE_ROOT:-$project_dir}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/composer-controls.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
python3 "$project_dir/Tests/UnifiedNavigation/ExtractProduction.py" "$source_root" "$check_dir/production"
python3 "$project_dir/Tests/ComposerControls/ExtractProduction.py" "$source_root" "$check_dir"
xcrun swiftc -D DEBUG -parse-as-library -module-cache-path "$check_dir/module-cache" \
 "$check_dir/production/AgentError.swift" "$check_dir/production/NavigationEnvironment.swift" \
 "$source_root/Shared/ComposerAttachment.swift" "$source_root/Shared/NativeTaskResult.swift" "$source_root/Shared/AssistantConversationContext.swift" "$source_root/Shared/ConversationUnderstanding.swift" \
 "$source_root/PhoneAgent/Stores/AssistantConversationStore.swift" "$source_root/PhoneAgent/Services/DidiChatSimulationRegistry.swift" "$source_root/PhoneAgent/Services/AssistantConversation.swift" \
 "$check_dir/production/ModelBoundaries.swift" "$project_dir/Tests/ComposerControls/main.swift" -o "$check_dir/checks"
"$check_dir/checks" "$check_dir/data" "${1:-$check_dir/result.json}"
