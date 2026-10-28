#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 "$project_dir/Tests/FirmwareClickOwnership/check.py" "$project_dir" "${1:-$(mktemp -d "${TMPDIR:-/tmp}/firmware-click-ownership.XXXXXX")}"
