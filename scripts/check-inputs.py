#!/usr/bin/env python3
"""Bind an offline check run to its app, harness, fixture and runner inputs."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("source_manifest", Path(__file__).with_name("source-manifest.py"))
source_manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source_manifest)


def entries(root):
    values = source_manifest.source_entries(root)
    for folder in ("Tests", "Tools", "scripts"):
        for path in sorted((root / folder).rglob("*")):
            if path.is_file() and not any(part in ("__pycache__", ".DS_Store") for part in path.relative_to(root).parts):
                values[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("create", "check"))
    parser.add_argument("root", type=Path)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--expected-digest")
    args = parser.parse_args()
    if args.operation == "check" and args.expected_digest is None:
        parser.error("check requires the digest captured before any suite ran")
    actual = entries(args.root.resolve())
    if args.operation == "create":
        digest = source_manifest.source_digest(actual)
        args.manifest.write_text(json.dumps({"schemaVersion": 1, "sha256": digest, "files": actual}, sort_keys=True) + "\n")
        print(digest)
        return
    saved = json.loads(args.manifest.read_text())
    if (saved.get("schemaVersion") != 1 or source_manifest.source_digest(saved["files"]) != saved["sha256"]
            or saved["sha256"] != args.expected_digest):
        raise SystemExit("Offline check input manifest differs from the captured digest; rerun from frozen sources")
    delta = source_manifest.changes(saved["files"], actual)
    if any(delta.values()):
        raise SystemExit("Offline check inputs changed during the run; results cannot describe one source version: " + json.dumps(delta, sort_keys=True))
    print("Offline check input identity verified: sha256:" + saved["sha256"] + " (" + str(len(actual)) + " files)")


if __name__ == "__main__":
    main()
