#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/model-credential-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
# Reuse the actual production URL policy without compiling network clients.
python3 - "$project_dir" "$check_dir" <<'PY'
from pathlib import Path
import sys
source = (Path(sys.argv[1]) / 'PhoneAgent/Services/VisionClient.swift').read_text()
start = source.index('enum ModelEndpointPolicy {')
end = source.index('private class ModelRedirectDelegate:', start)
(Path(sys.argv[2]) / 'ModelEndpointPolicy.swift').write_text('import Foundation\n' + source[start:end])
PY
xcrun swiftc -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Tests/ModelCredentials/Environment.swift" \
  "$check_dir/ModelEndpointPolicy.swift" \
  "$project_dir/Shared/ModelConnectionCredentials.swift" \
  "$project_dir/PhoneAgent/Stores/SettingsStore.swift" \
  "$project_dir/Tests/ModelCredentials/main.swift" -o "$check_dir/checks"
"$check_dir/checks"
