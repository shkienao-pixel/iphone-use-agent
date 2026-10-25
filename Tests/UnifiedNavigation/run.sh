#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_root="${PHONE_TEST_SOURCE_ROOT:-$project_dir}"
check_dir="${PHONE_NAVIGATION_EVIDENCE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/unified-navigation.XXXXXX")}"
mkdir -p "$check_dir"
python3 "$project_dir/Tests/UnifiedNavigation/ExtractProduction.py" "$source_root" "$check_dir/production"
understanding_sources=()
if [[ -f "$source_root/Shared/ConversationUnderstanding.swift" ]]; then
 understanding_sources+=("$source_root/Shared/ConversationUnderstanding.swift")
fi
xcrun swiftc -D DEBUG -parse-as-library -module-cache-path "$check_dir/module-cache" \
 "$check_dir/production/AgentError.swift" "$check_dir/production/NavigationEnvironment.swift" \
 "$source_root/Shared/ComposerAttachment.swift" "$source_root/Shared/NativeTaskResult.swift" "$source_root/Shared/AssistantConversationContext.swift" "${understanding_sources[@]}" \
 "$source_root/PhoneAgent/Stores/AssistantConversationStore.swift" "$source_root/PhoneAgent/Services/AssistantConversation.swift" \
 "$check_dir/production/ModelBoundaries.swift" "$project_dir/Tests/UnifiedNavigation/main.swift" \
 -o "$check_dir/unified-navigation"
"$check_dir/unified-navigation" "$check_dir/result.json"
