#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/conversation-lifecycle-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/ComposerAttachment.swift" \
  "$project_dir/Shared/NativeTaskResult.swift" "$project_dir/Shared/AssistantConversationContext.swift" "$project_dir/Shared/ConversationUnderstanding.swift" \
  "$project_dir/PhoneAgent/Stores/AssistantConversationStore.swift" \
  "$project_dir/PhoneAgent/Services/AssistantConversation.swift" \
  "$project_dir/Tests/AssistantConversation/Environment.swift" \
  "$project_dir/Tests/ConversationLifecycle/main.swift" \
  -o "$check_dir/conversation-lifecycle-checks"
"$check_dir/conversation-lifecycle-checks"

# Compile the complete production composer send/helper/change callback against
# the real attachment store/importer and conversation archive. Only platform
# media/readiness and model transport are explicit offline boundaries.
python3 "$project_dir/Tests/ConversationLifecycle/ExtractPresentation.py" "$project_dir" "$check_dir"
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/ComposerAttachment.swift" "$project_dir/Shared/VoiceCommand.swift" \
  "$project_dir/Shared/NativeTaskResult.swift" "$project_dir/Shared/AssistantConversationContext.swift" "$project_dir/Shared/ConversationUnderstanding.swift" \
  "$project_dir/PhoneAgent/Stores/AssistantConversationStore.swift" \
  "$project_dir/PhoneAgent/Services/AssistantConversation.swift" \
  "$project_dir/PhoneAgent/Stores/ComposerAttachmentStore.swift" \
  "$project_dir/PhoneAgent/Services/ComposerAttachmentImport.swift" \
  "$project_dir/PhoneAgent/Services/OfficeTextImport.swift" "$project_dir/PhoneAgent/Services/LocalFileRecognition.swift" \
  "$project_dir/Tests/AssistantConversation/Environment.swift" "$check_dir/PresentationHarness.swift" \
  "$project_dir/Tests/ConversationLifecycle/PresentationAttachmentChecks.swift" \
  -lz -o "$check_dir/presentation-attachment-checks"
"$check_dir/presentation-attachment-checks"
