#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/wechat-contact-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Tests/ChatEvidence/Stubs.swift" \
  "$project_dir/Shared/PhoneHarness.swift" \
  "$project_dir/Shared/PhonePageAdapters.swift" \
  "$project_dir/Shared/PhoneVisualControls.swift" \
  "$project_dir/Shared/XiaohongshuPageAdapter.swift" \
  "$project_dir/Shared/WeChatContactIdentity.swift" \
  "$project_dir/Shared/ChatEvidence.swift" \
  "$project_dir/PhoneAgent/Stores/ChatEvidenceStore.swift" \
  "$project_dir/PhoneAgent/Services/ChatEvidenceReader.swift" \
  "$project_dir/PhoneAgent/Services/ChatEvidenceSummarizer.swift" \
  "$project_dir/PhoneAgent/Services/WeChatConversationDriver.swift" \
  "$project_dir/Tests/Contacts/CurrentPageRangeChecks.swift" \
  "$project_dir/Tests/Contacts/SystemIntroChecks.swift" \
  "$project_dir/Tests/Contacts/main.swift" -o "$check_dir/checks"
"$check_dir/checks"
