#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/sela-paotui-chat.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
sed '/^import UIKit$/d' "$project_dir/PhoneAgent/Services/MeituanPaotuiStore.swift" > "$test_dir/ProductionStore.swift"
sed '/^import UIKit$/d' "$project_dir/PhoneAgent/Services/MeituanPaotuiConversation.swift" > "$test_dir/ProductionConversation.swift"
swiftc -parse-as-library "$project_dir/Shared/ComposerAttachment.swift" "$project_dir/Shared/NativeTaskResult.swift" "$project_dir/Shared/AssistantConversationContext.swift" "$project_dir/Shared/ConversationUnderstanding.swift" "$project_dir/PhoneAgent/Models/MeituanPaotui.swift" "$project_dir/PhoneAgent/Services/MeituanPaotuiClient.swift" "$test_dir/ProductionStore.swift" "$test_dir/ProductionConversation.swift" "$project_dir/Tests/PaotuiConversation/Environment.swift" "$project_dir/Tests/PaotuiConversation/main.swift" -o "$test_dir/checks"
"$test_dir/checks"
swiftc -parse-as-library "$project_dir/Shared/ComposerAttachment.swift" "$project_dir/Shared/NativeTaskResult.swift" "$project_dir/Shared/AssistantConversationContext.swift" "$project_dir/Shared/ConversationUnderstanding.swift" "$project_dir/PhoneAgent/Models/MeituanPaotui.swift" "$project_dir/PhoneAgent/Services/MeituanPaotuiClient.swift" "$test_dir/ProductionStore.swift" "$test_dir/ProductionConversation.swift" "$project_dir/Tests/PaotuiConversation/Environment.swift" "$project_dir/Tests/PaotuiConversation/refinements.swift" -o "$test_dir/refinements"
"$test_dir/refinements"
swiftc -parse-as-library "$project_dir/Shared/ComposerAttachment.swift" "$project_dir/Shared/NativeTaskResult.swift" "$project_dir/Shared/AssistantConversationContext.swift" "$project_dir/Shared/ConversationUnderstanding.swift" "$project_dir/PhoneAgent/Stores/AssistantConversationStore.swift" "$project_dir/PhoneAgent/Services/AssistantConversation.swift" "$project_dir/Tests/AssistantConversation/Environment.swift" "$project_dir/Tests/PaotuiConversation/host.swift" -o "$test_dir/host-checks"
"$test_dir/host-checks"
