#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/sela-markdown-table.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
swiftc "$project_dir/PhoneAgent/Views/SelaMarkdownTable.swift" "$project_dir/Tests/MarkdownTable/main.swift" -o "$scratch/checks"
"$scratch/checks"
