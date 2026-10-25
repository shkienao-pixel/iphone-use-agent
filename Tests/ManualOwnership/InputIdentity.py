#!/usr/bin/env python3
"""Bind one run to current whole production files and its complete target set."""
from pathlib import Path
import hashlib
import json
import sys

PRODUCTION = ["PhoneAgent/PhoneAgentViewModel.swift", "PhoneAgent/Services/BLETransport.swift",
              "Shared/InputReleaseController.swift"]


def digest(files):
    return hashlib.sha256(json.dumps(files, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def entries(root, target):
    files = {"production:" + name: hashlib.sha256((root / name).read_bytes()).hexdigest()
             for name in PRODUCTION}
    for path in sorted(target.rglob("*")):
        if path.is_file() and not any(part in ("__pycache__", ".DS_Store") for part in path.relative_to(target).parts):
            files["target:" + str(path.relative_to(target))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return files


def main():
    mode, root, target, path = sys.argv[1], Path(sys.argv[2]).resolve(), Path(sys.argv[3]).resolve(), Path(sys.argv[4])
    actual = entries(root, target)
    if mode == "create":
        assert not path.exists(), "Preserve each input capture"
        value = {"schemaVersion": 1, "sourceRoot": str(root), "targetRoot": str(target),
                 "sha256": digest(actual), "files": actual}
        path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
        print(value["sha256"])
        return
    assert mode == "check" and len(sys.argv) == 6
    saved = json.loads(path.read_text())
    assert saved["schemaVersion"] == 1 and saved["sourceRoot"] == str(root) and saved["targetRoot"] == str(target)
    assert digest(saved["files"]) == saved["sha256"] == sys.argv[5], "Input capture changed after admission"
    delta = {"added": sorted(actual.keys() - saved["files"].keys()),
             "removed": sorted(saved["files"].keys() - actual.keys()),
             "changed": sorted(name for name in actual.keys() & saved["files"].keys() if actual[name] != saved["files"][name])}
    assert not any(delta.values()), "ManualOwnership inputs changed: " + json.dumps(delta, sort_keys=True)
    print("ManualOwnership input identity verified: sha256:" + saved["sha256"] + " (" + str(len(actual)) + " files)")


if __name__ == "__main__":
    main()
