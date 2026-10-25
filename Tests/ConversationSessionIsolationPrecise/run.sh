#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_root="${PHONE_TEST_SOURCE_ROOT:-$project_dir}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/session-isolation-checks.XXXXXX")"
finish() {
  local result=$?
  if [[ "$result" -ne 0 ]]; then
    echo "Session isolation failure evidence preserved: $check_dir" >&2
  else
    rm -rf "$check_dir"
  fi
  exit "$result"
}
trap finish EXIT
mkdir -p "$check_dir/precise-tests" "$check_dir/tests/module-cache"
cp "$project_dir/Tests/ConversationSessionIsolationPrecise/"{extract.py,run.py,Scaffold.swift,main.swift} "$check_dir/precise-tests/"
python3 "$check_dir/precise-tests/run.py" --source-root "$source_root"
