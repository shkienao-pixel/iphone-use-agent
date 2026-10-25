#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/sela-memory-integration.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
mkdir -p "$check_dir/Sources/Check"
cp "$project_dir/PhoneAgent/Services/SelaMemoryModelClient.swift" "$project_dir/PhoneAgent/Services/SelaMemoryService.swift" "$project_dir/PhoneAgent/Services/ConnectedConversationClient.swift" "$project_dir/Tests/MemoryIntegration/Environment.swift" "$project_dir/Tests/MemoryIntegration/main.swift" "$check_dir/Sources/Check/"
cp "$project_dir/Shared/ChatGPTPlanProtocol.swift" "$project_dir/Shared/ChatGPTPlanResponses.swift" "$project_dir/PhoneAgent/Services/ChatGPTPlanRuntime.swift" "$check_dir/Sources/Check/"
python3 - "$project_dir" "$check_dir" <<'PY'
from pathlib import Path
import sys,json
root,out=map(Path,sys.argv[1:])
path=json.dumps(str(root/'PhoneAgent/SelaMemoryCore'))
(out/'Package.swift').write_text('// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "MemoryIntegration", platforms: [.macOS(.v14)], dependencies: [.package(path: '+path+')], targets: [.executableTarget(name: "Check", dependencies: [.product(name: "SelaMemoryCore", package: "SelaMemoryCore")])], swiftLanguageModes: [.v5])\n')
PY
swift build --package-path "$check_dir" --scratch-path "$check_dir/build" --jobs 2 >/dev/null
SELA_MEMORY_CHECK_ROOT="$check_dir/data" "$check_dir/build/debug/Check" "$@"
