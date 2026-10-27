#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/sela-background-execution.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -emit-library -emit-module -module-name UIKit "$project_dir/Tests/BackgroundExecution/FakeUIKit.swift" -o "$check_dir/libUIKit.dylib" -emit-module-path "$check_dir/UIKit.swiftmodule"
xcrun swiftc -emit-library -emit-module -module-name BackgroundTasks "$project_dir/Tests/BackgroundExecution/FakeBackgroundTasks.swift" -o "$check_dir/libBackgroundTasks.dylib" -emit-module-path "$check_dir/BackgroundTasks.swiftmodule"
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" -I "$check_dir" -L "$check_dir" -lUIKit -lBackgroundTasks -Xlinker -rpath -Xlinker "$check_dir" "$project_dir/PhoneAgent/Services/BackgroundExecutionController.swift" "$project_dir/Tests/BackgroundExecution/main.swift" -o "$check_dir/check"
"$check_dir/check"
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" -I "$check_dir" -L "$check_dir" -lUIKit -lBackgroundTasks -Xlinker -rpath -Xlinker "$check_dir" \
  "$project_dir/Shared/ComposerAttachment.swift" "$project_dir/Shared/NativeTaskResult.swift" "$project_dir/Shared/ToolReceiptMaintenance.swift" \
  "$project_dir/PhoneAgent/Stores/TaskHistoryStore.swift" "$project_dir/PhoneAgent/Services/BackgroundTaskCoordinator.swift" \
  "$project_dir/Tests/TaskCoordinatorPersistence/Environment.swift" "$project_dir/PhoneAgent/Services/BackgroundExecutionController.swift" \
  "$project_dir/Tests/BackgroundExecution/CoordinatorMain.swift" -o "$check_dir/coordinator-check"
"$check_dir/coordinator-check"
xcrun swiftc -emit-library -emit-module -module-name ActivityKit "$project_dir/Tests/BackgroundExecution/FakeActivityKit.swift" -o "$check_dir/libActivityKit.dylib" -emit-module-path "$check_dir/ActivityKit.swiftmodule"
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/module-cache" -I "$check_dir" -L "$check_dir" -lUIKit -lActivityKit -Xlinker -rpath -Xlinker "$check_dir" "$project_dir/Shared/AgentActivityAttributes.swift" "$project_dir/Tests/BackgroundExecution/ActivityEnvironment.swift" "$project_dir/PhoneAgent/Services/TaskActivityController.swift" "$project_dir/Tests/BackgroundExecution/ActivityMain.swift" -o "$check_dir/activity-check"
"$check_dir/activity-check"
