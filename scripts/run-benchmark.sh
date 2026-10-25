#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/phone-benchmark.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -module-cache-path "$check_dir/module-cache" -parse-as-library \
  "$project_dir/Shared/RunMetrics.swift" "$project_dir/Tools/RunBenchmark.swift" -o "$check_dir/run-benchmark"
"$check_dir/run-benchmark" "$@"
