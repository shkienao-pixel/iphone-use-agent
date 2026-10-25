#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-plan-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
python3 - "$project_dir" "$check_dir/Readiness.swift" <<'PY'
from pathlib import Path
import sys
root, out = Path(sys.argv[1]), Path(sys.argv[2])
def member(text, signature):
    assert text.count(signature) == 1, signature
    start=text.index(signature); cursor=text.index('{',start)+1; depth=1
    while depth:
        depth += (text[cursor]=='{')-(text[cursor]=='}'); cursor+=1
    return text[start:cursor]
policy=member((root/'PhoneAgent/Services/VisionClient.swift').read_text(),'enum ModelEndpointPolicy {')
ready=member((root/'PhoneAgent/PhoneAgentViewModel.swift').read_text(),'    var modelReady: Bool {')
out.write_text('import Foundation\n'+policy+'\n' + '''
enum SettingsStore {
    static var fixtureCredential = ""
    static func apiKey(for endpoint: String) -> String { fixtureCredential }
}
struct ModelReadinessProbe {
    var settings: AgentSettings
'''+ready+'\n}\n')
PY
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/ChatGPTPlanProtocol.swift" "$project_dir/Shared/ChatGPTPlanResponses.swift" \
  "$project_dir/Shared/SystemToolRequest.swift" "$project_dir/Shared/PhoneHarness.swift" \
  "$project_dir/Shared/AgentModels.swift" "$project_dir/Shared/MouseProtocol.swift" \
  "$check_dir/Readiness.swift" \
  "$project_dir/Tests/ChatGPTPlan/main.swift" -o "$check_dir/checks"
"$check_dir/checks"
