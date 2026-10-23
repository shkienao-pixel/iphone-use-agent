#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/phone-product-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT

# Keep the production engine intact except for the platform image import.
python3 - "$project_dir/PhoneAgent/Services/AgentEngine.swift" "$check_dir/Engine.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
assert source.count('import UIKit') == 1
Path(sys.argv[2]).write_text(source.replace('import UIKit', 'import CoreGraphics'))
PY
xcrun swiftc -module-cache-path "$check_dir/module-cache" -parse-as-library \
  "$project_dir/Shared/SystemToolRequest.swift" \
  "$project_dir/Shared/PhoneHarness.swift" "$project_dir/Shared/AgentModels.swift" \
  "$project_dir/Shared/MouseProtocol.swift" \
  "$project_dir/Shared/VoiceCommand.swift" \
  "$project_dir/PhoneAgent/Stores/TaskHistoryStore.swift" \
  "$project_dir/PhoneAgent/Services/PrivacyConsent.swift" \
  "$project_dir/Tests/ProductState/Environment.swift" \
  "$check_dir/Engine.swift" \
  "$project_dir/Tests/ProductState/main.swift" \
  -o "$check_dir/phone-product-checks"
"$check_dir/phone-product-checks"
