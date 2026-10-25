#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
env -u SELA_ACTIVITY_LAB -u SELA_TEST_OUTPUT python3 "$project_dir/Tests/SimulatorTransport/main.py"
