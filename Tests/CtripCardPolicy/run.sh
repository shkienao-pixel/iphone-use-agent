#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/sela-ctripcardpolicy.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
python3 "$project_dir/Tests/CtripCardPolicy/run-policy.py" --source-root "$project_dir" --output-dir "$check_dir"
