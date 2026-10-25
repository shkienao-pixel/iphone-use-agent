#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/notes-shortcut-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
python3 - "$project_dir/PhoneAgent/Services/NotesShortcutBridge.swift" "$check_dir/NotesShortcutBridge.swift" <<'PY'
import pathlib, sys
s=pathlib.Path(sys.argv[1]).read_text()
assert s.count('import UIKit') == 1
pathlib.Path(sys.argv[2]).write_text(s.replace('import UIKit', 'import Foundation', 1))
PY
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/NotesShortcutContract.swift" "$project_dir/Tests/NotesShortcut/Environment.swift" \
  "$check_dir/NotesShortcutBridge.swift" "$project_dir/Tests/NotesShortcut/main.swift" -o "$check_dir/checks"
"$check_dir/checks"
