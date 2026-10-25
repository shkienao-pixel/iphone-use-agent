#!/usr/bin/env python3
"""Read-only module boundary check; writes its report only inside verification/."""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import sys

module = Path(__file__).resolve().parents[1]
root = module.parents[1]
baseline = json.loads((module / "verification/host-baseline.json").read_text())
changed = []
missing = []
for relative, expected in baseline.items():
    path = root / relative
    if not path.is_file():
        missing.append(relative)
    elif hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        changed.append(relative)

new_host_files = []
for directory in ("PhoneAgent", "Shared", "Activity", "Skills", "Tests", "scripts"):
    for path in (root / directory).rglob("*"):
        if path.is_file() and not any(part in (".build", "__pycache__") for part in path.parts):
            relative = str(path.relative_to(root))
            if relative not in baseline:
                new_host_files.append(relative)

package = json.loads(subprocess.check_output(["swift", "package", "--package-path", str(module), "dump-package"], text=True))
imports = {}
for path in (module / "Sources").rglob("*.swift"):
    imports[str(path.relative_to(module))] = re.findall(r"^import ([A-Za-z0-9_]+)$", path.read_text(), re.M)
unexpected_imports = {p: names for p, names in imports.items() if set(names) - {"Foundation", "Darwin", "Glibc"}}
bad_targets = []
for target in package["targets"]:
    if target.get("path", "").startswith(("..", "/")):
        bad_targets.append(target["name"])

bad_links = []
for path in (module / "Skills").rglob("*.md"):
    for link in re.findall(r"\]\(([^)]+)\)", path.read_text()):
        if "://" in link or link.startswith("#"):
            continue
        if not (path.parent / link.split("#")[0]).is_file():
            bad_links.append({"file": str(path.relative_to(module)), "link": link})

integration_references = []
for directory in ("PhoneAgent", "Shared", "Activity", "Skills", "scripts", "PhoneAgent.xcodeproj"):
    for path in (root / directory).rglob("*"):
        if path.is_file() and path.suffix in (".swift", ".md", ".py", ".sh", ".pbxproj"):
            content = path.read_text(errors="replace")
            if any(token in content for token in ("WeChatSkillCore", "wechat-assistant", "wechat-skill-20261025")):
                integration_references.append(str(path.relative_to(root)))

report = {
    "baseline_host_file_count": len(baseline),
    "host_changed_since_baseline": changed,
    "host_missing_since_baseline": missing,
    "host_added_since_baseline": new_host_files,
    "host_baseline_unchanged": not any((changed, missing, new_host_files)),
    "host_drift_note": "Shared-workspace changes are reported separately; this read-only check neither attributes nor reverts them.",
    "package_dependencies": package["dependencies"],
    "source_imports": imports,
    "unexpected_imports": unexpected_imports,
    "external_target_paths": bad_targets,
    "broken_skill_reference_links": bad_links,
    "host_integration_references": integration_references,
    "skill_entry_bytes": (module / "Skills/wechat-assistant/SKILL.md").stat().st_size,
    "app_integration_performed": False,
    "device_actions_performed": False,
}
report["passed"] = not any((package["dependencies"], unexpected_imports, bad_targets, bad_links, integration_references))
(module / "verification/isolation.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({key: report[key] for key in ("passed", "baseline_host_file_count", "host_baseline_unchanged", "host_integration_references", "skill_entry_bytes")}, ensure_ascii=False))
sys.exit(0 if report["passed"] else 1)
