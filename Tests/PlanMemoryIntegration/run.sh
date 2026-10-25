#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/sela-plan-memory.XXXXXX")"
finish() {
  result=$?
  if [[ "$result" == 0 ]]; then rm -rf "$check_dir"; else echo "Retained offline fixture: $check_dir" >&2; fi
  exit "$result"
}
trap finish EXIT
mkdir -p "$check_dir/Sources/Check"
cp "$project_dir/PhoneAgent/Services/SelaMemoryModelClient.swift" "$project_dir/PhoneAgent/Services/SelaMemoryService.swift" "$project_dir/PhoneAgent/Services/ConnectedConversationClient.swift" "$project_dir/Tests/MemoryIntegration/Environment.swift" "$check_dir/Sources/Check/"
cp "$project_dir/Shared/ChatGPTPlanProtocol.swift" "$project_dir/Shared/ChatGPTPlanResponses.swift" "$check_dir/Sources/Check/"
cp "$project_dir/Tests/PlanMemoryIntegration/Environment.swift" "$check_dir/Sources/Check/PlanEnvironment.swift"
cp "$project_dir/Tests/PlanMemoryIntegration/main.swift" "$check_dir/Sources/Check/main.swift"
python3 - "$project_dir" "$check_dir" <<'PY'
import pathlib,sys,json
root,out=map(pathlib.Path,sys.argv[1:])
source=(root/'PhoneAgent/Services/ChatGPTPlanRuntime.swift').read_text()
def member(signature):
    assert source.count(signature)==1
    start=source.index(signature);cursor=source.index('{',start)+1;depth=1
    while depth:
        depth+=(source[cursor]=='{')-(source[cursor]=='}');cursor+=1
    return source[start:cursor]
actor=member('actor ChatGPTPlanTokens {')
binding=member('    static func readinessToken() -> String {')
save=member('    static func save(_ profile: ChatGPTPlanProfile, expectedRefreshToken: String? = nil, select: Bool) throws {')
stub='''import Foundation
enum ChatGPTPlanStore {
    private static let lock = NSRecursiveLock()
    private static var value: ChatGPTPlanProfile?
    static var fixture: ChatGPTPlanProfile? { get { lock.lock(); defer { lock.unlock() }; return value } set { lock.lock(); defer { lock.unlock() }; value = newValue } }
    static func selected() -> ChatGPTPlanProfile? { fixture }
    static func active(_ id: UUID) -> Bool { fixture?.id == id }
    struct Document { var profiles: [ChatGPTPlanProfile]; var selectedID: UUID? }
    private static func readUnlocked() throws -> Document? {
        fixture.map { Document(profiles: [$0], selectedID: $0.id) }
    }
    private static func writeUnlocked(_ document: Document) throws { fixture = document.profiles.first { $0.id == document.selectedID } }
'''+binding+'\n'+save+'\n}\n'+actor
(out/'Sources/Check/PlanRuntime.swift').write_text(stub)
package='// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "PlanMemoryIntegration", platforms: [.macOS(.v14)], dependencies: [.package(path: '+json.dumps(str(root/'PhoneAgent/SelaMemoryCore'))+')], targets: [.executableTarget(name: "Check", dependencies: [.product(name: "SelaMemoryCore", package: "SelaMemoryCore")])], swiftLanguageModes: [.v5])\n'
(out/'Package.swift').write_text(package)
PY
swift build --package-path "$check_dir" --scratch-path "$check_dir/build" --jobs 2 >/dev/null
SELA_MEMORY_CHECK_ROOT="$check_dir/data" "$check_dir/build/debug/Check"
