#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
swiftc Shared/CtripGroundTravel.swift Tests/CtripGroundTravel/main.swift -o "$scratch/checks"
"$scratch/checks"
