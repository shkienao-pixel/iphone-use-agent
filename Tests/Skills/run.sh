#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ $# -ne 1 ]]; then
  echo "Usage: bash Tests/Skills/run.sh /path/to/built/PhoneAgent.app" >&2
  exit 2
fi
built_app="$1"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/phone-skill-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -module-cache-path "$check_dir/module-cache" "$project_dir/Shared/SystemToolRequest.swift" "$project_dir/Shared/PhoneHarness.swift" "$project_dir/Shared/AgentModels.swift" "$project_dir/PhoneAgent/Services/PhoneControlSkill.swift" \
  "$project_dir/PhoneAgent/Services/NativeSkillCatalog.swift" "$project_dir/PhoneAgent/Services/PhoneAppSkillCatalog.swift" \
  "$project_dir/PhoneAgent/Services/ConversationIntentSkill.swift" \
  "$project_dir/Tests/Skills/main.swift" -o "$check_dir/skill-checks"
"$check_dir/skill-checks" "$built_app"
