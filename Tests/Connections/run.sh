#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checks_dir="$(mktemp -d "${TMPDIR:-/tmp}/sela-connections.XXXXXX")"
trap 'rm -rf "$checks_dir"' EXIT
mkdir "$checks_dir/Home.bundle"
cp "$project_dir/PhoneAgent/Resources/SelaHomeRules.js" "$project_dir/PhoneAgent/Resources/SelaTaskCatalog.json" "$checks_dir/Home.bundle/"
python3 - "$checks_dir/Home.bundle/Info.plist" <<'PY'
import plistlib,sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.sela.homechecks','CFBundlePackageType':'BNDL'}))
PY
swiftc -parse-as-library "$project_dir/PhoneAgent/Services/SelaHomeContext.swift" "$project_dir/Tests/Connections/home.swift" -o "$checks_dir/home"
TZ=Asia/Shanghai "$checks_dir/home" "$checks_dir/Home.bundle"
swiftc -parse-as-library "$project_dir/Shared/SystemToolRequest.swift" "$project_dir/Shared/NativeToolData.swift" "$project_dir/Tests/Connections/native_tool_contracts.swift" -o "$checks_dir/native"
"$checks_dir/native"
swiftc -parse-as-library "$project_dir/PhoneAgent/Services/OfficeAuthorizationModels.swift" "$project_dir/PhoneAgent/Services/OfficeAuthorizationPolicy.swift" "$project_dir/PhoneAgent/Services/OfficeAuthorizationFlow.swift" "$project_dir/PhoneAgent/Services/OfficeAuthorizationQRCode.swift" "$project_dir/Tests/Connections/authorization.swift" -o "$checks_dir/authorization"
"$checks_dir/authorization"
