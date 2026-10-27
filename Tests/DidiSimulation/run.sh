#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/didi-service.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
# Compile the exact production domain declarations, including displayPrice,
# without importing the SwiftUI view or inventing a matching test renderer.
python3 - "$project_dir" "$check_dir" <<'PYEXTRACT'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
source = (root/'PhoneAgent/Views/DidiRideSimulationView.swift').read_text()
marker = '/// Real location and read-only map/quote data; order progress is local simulation.'
if source.count(marker) != 1:
    raise SystemExit('Production domain extraction anchor changed')
(out/'Domain.swift').write_text(source.split(marker, 1)[0])
PYEXTRACT
xcrun swiftc -parse-as-library "$project_dir/PhoneAgent/Services/DidiSimulationService.swift" "$project_dir/PhoneAgent/Services/DidiChatSimulationRegistry.swift" "$check_dir/Domain.swift" "$project_dir/Tests/DidiSimulation/main.swift" -o "$check_dir/checks"
"$check_dir/checks"
