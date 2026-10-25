#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/sela-xhs-mcp.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library "$project_dir/Shared/ComposerAttachment.swift" "$project_dir/Shared/AssistantConversationContext.swift" \
 "$project_dir/PhoneAgent/Services/XiaohongshuMCPClient.swift" "$project_dir/PhoneAgent/Services/XiaohongshuLocalMCP.swift" "$project_dir/PhoneAgent/Services/XiaohongshuMCPStore.swift" \
 "$project_dir/Tests/XiaohongshuMCP/main.swift" -o "$test_dir/checks"
"$test_dir/checks"
node "$project_dir/Tests/XiaohongshuMCP/reader.js"
swiftc -parse-as-library "$project_dir/Shared/ComposerAttachment.swift" "$project_dir/Shared/AssistantConversationContext.swift" \
 "$project_dir/PhoneAgent/Stores/AssistantConversationStore.swift" "$project_dir/PhoneAgent/Services/AssistantConversation.swift" \
 "$project_dir/Tests/AssistantConversation/Environment.swift" "$project_dir/Tests/XiaohongshuMCP/host.swift" -o "$test_dir/host"
"$test_dir/host"
