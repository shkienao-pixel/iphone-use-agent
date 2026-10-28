#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/sela-memory-integration.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
mkdir -p "$check_dir/Sources/Check"
cp "$project_dir/PhoneAgent/Services/SelaMemoryModelClient.swift" "$project_dir/PhoneAgent/Services/SelaMemoryService.swift" "$project_dir/PhoneAgent/Services/ConnectedConversationClient.swift" "$project_dir/Tests/MemoryIntegration/Environment.swift" "$project_dir/Tests/MemoryIntegration/main.swift" "$project_dir/Tests/MemoryIntegration/PresentationChecks.swift" "$check_dir/Sources/Check/"
cp "$project_dir/Shared/ChatGPTPlanProtocol.swift" "$project_dir/Shared/ChatGPTPlanResponses.swift" "$project_dir/PhoneAgent/Services/ChatGPTPlanRuntime.swift" "$check_dir/Sources/Check/"
cp "$project_dir/Shared/ComposerAttachment.swift" "$project_dir/Shared/NativeTaskResult.swift" "$project_dir/Shared/AssistantConversationContext.swift" "$project_dir/Shared/ConversationUnderstanding.swift" "$check_dir/Sources/Check/"
cp "$project_dir/PhoneAgent/Services/AssistantConversation.swift" "$project_dir/PhoneAgent/Stores/AssistantConversationStore.swift" "$project_dir/PhoneAgent/Services/DidiChatSimulationRegistry.swift" "$check_dir/Sources/Check/"
python3 - "$project_dir" "$check_dir" <<'PY'
from pathlib import Path
import sys,json
root,out=map(Path,sys.argv[1:])
# Reuse only existing offline platform/model boundaries. AssistantMessage,
# conversation/store, host card updates and memory service compile unchanged.
def member(text, signature):
    assert text.count(signature)==1,signature
    start=text.index(signature); cursor=text.index('{',start)+1; depth=1
    while depth:
        depth+=(text[cursor]=='{')-(text[cursor]=='}');cursor+=1
    return text[start:cursor]
boundaries=(root/'Tests/AssistantConversation/Environment.swift').read_text()
signatures=['struct ScreenFrame {','struct CameraObservationFrame {','struct AgentLogEntry {','enum TaskOutcome {','struct PhoneTaskRecord {','@MainActor final class MemoryStore {','@MainActor final class OfflineModel {','@MainActor struct VisionClient {']
(out/'Sources/Check/ConversationBoundary.swift').write_text('import Foundation\n'+'\n'.join(member(boundaries,key) for key in signatures)+'\n')

path=json.dumps(str(root/'PhoneAgent/SelaMemoryCore'))
(out/'Package.swift').write_text('// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "MemoryIntegration", platforms: [.macOS(.v14)], dependencies: [.package(path: '+path+')], targets: [.executableTarget(name: "Check", dependencies: [.product(name: "SelaMemoryCore", package: "SelaMemoryCore")])], swiftLanguageModes: [.v5])\n')
PY
swift build --package-path "$check_dir" --scratch-path "$check_dir/build" --jobs 2 >/dev/null
SELA_MEMORY_CHECK_ROOT="$check_dir/data" "$check_dir/build/debug/Check" "$@"
