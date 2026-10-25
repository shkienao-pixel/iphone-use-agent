#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
platform="${1:-simulator}"
case "$platform" in
  simulator) destination='generic/platform=iOS Simulator' ;;
  device) destination='generic/platform=iOS' ;;
  *) echo 'Usage: bash scripts/build-verified.sh [simulator|device] [output-directory]' >&2; exit 2 ;;
esac
output_dir="${2:-$project_dir/output/reliability-20261023-v4/candidate-$platform}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
# One owner per artifact directory; another invocation must use another folder.
# A stale lock is preserved for inspection rather than silently taken over.
if ! mkdir "$output_dir/.build-verified.lock"; then
  echo 'Build output is already locked; use another output directory or inspect the prior interrupted build.' >&2
  exit 1
fi
finish_build() {
  local result=$?
  trap - EXIT
  rmdir "$output_dir/.build-verified.lock"
  # Maintenance cannot change a compiler/check result, and this build remains
  # protected even while the post-build source identity check is complete.
  if ! python3 "$project_dir/scripts/cleanup-build-artifacts.py" --apply --protect "$output_dir"; then
    echo 'Build maintenance deferred; the hourly maintenance job will retry.' >&2
  fi
  exit "$result"
}
trap finish_build EXIT
touch "$output_dir/.build-retention-touch"
# Content addresses bind the binary to the exact saved sources, including new
# uncommitted files. Neither git status nor a baseline SHA alone can do that.
python3 "$project_dir/scripts/source-manifest.py" create "$project_dir" "$output_dir"
source_revision="$(cat "$output_dir/source-revision.txt")"
xcodebuild -project "$project_dir/PhoneAgent.xcodeproj" -scheme PhoneAgent \
  -configuration Debug -destination "$destination" -derivedDataPath "$output_dir/build" \
  CODE_SIGNING_ALLOWED=NO "PHONE_AGENT_SOURCE_REVISION=$source_revision" \
  PHONE_AGENT_HARNESS_VERSION=reliability-v4 build
python3 "$project_dir/scripts/source-manifest.py" check "$project_dir" "$output_dir" --expected-revision "$source_revision"
