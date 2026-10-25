#!/usr/bin/env python3
"""Content identity for the app build, including files added during a build."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import subprocess


SOURCE_FOLDERS = ("PhoneAgent", "Shared", "Activity", "Skills", "firmware")


def source_entries(root):
    root = Path(root)
    paths = []
    for folder in SOURCE_FOLDERS:
        parent = root / folder
        for path in parent.rglob("*"):
            if path.is_file() and not any(
                part.startswith("build") or part in (".build", ".swiftpm", "managed_components", "__pycache__")
                for part in path.relative_to(parent).parts
            ):
                paths.append(path)
    paths.append(root / "PhoneAgent.xcodeproj/project.pbxproj")
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(paths)}


def source_digest(entries):
    return hashlib.sha256(json.dumps(entries, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def changes(expected, actual):
    return {
        "added": sorted(actual.keys() - expected.keys()),
        "removed": sorted(expected.keys() - actual.keys()),
        "modified": sorted(name for name in expected.keys() & actual.keys() if expected[name] != actual[name]),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("create", "check"))
    parser.add_argument("root", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--expected-revision", help="exact revision passed to this build's compiler invocation")
    args = parser.parse_args()
    if args.operation == "check" and args.expected_revision is None:
        parser.error("check requires --expected-revision captured before the build")
    root, output = args.root.resolve(), args.output.resolve()
    actual = source_entries(root)
    manifest_path = output / "source-manifest.json"
    if args.operation == "create":
        base = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
        digest = source_digest(actual)
        revision = base + "+sha256:" + digest
        manifest = {"created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(), "git_head": base,
                    "source_revision": revision, "source_sha256": digest, "files": actual,
                    "harness_version": "reliability-v4", "firmware_version": "unknown",
                    "signing": "disabled; this command does not install or exercise hardware"}
        output.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
        (output / "source-revision.txt").write_text(revision)
    else:
        manifest = json.loads(manifest_path.read_text())
        expected = manifest["files"]
        if source_digest(expected) != manifest["source_sha256"]:
            raise SystemExit("Invalid source manifest digest; discard this binary and rebuild")
        revision = manifest["git_head"] + "+sha256:" + manifest["source_sha256"]
        if (manifest["source_revision"] != revision or
                (output / "source-revision.txt").read_text() != revision or
                args.expected_revision != revision):
            raise SystemExit("Build revision differs from the captured compiler revision; discard this binary and rebuild")
        delta = changes(expected, actual)
        if any(delta.values()):
            raise SystemExit("Source changed during build; discard this binary and rebuild: " + json.dumps(delta, sort_keys=True))
        print("Build source identity verified: " + manifest["source_revision"])


if __name__ == "__main__":
    main()
