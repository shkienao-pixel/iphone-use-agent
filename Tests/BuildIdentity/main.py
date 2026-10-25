#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/source-manifest.py"
spec = importlib.util.spec_from_file_location("source_manifest", SCRIPT)
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)


class BuildIdentityChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="build-identity-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "source with spaces"
        self.output = Path(self.temporary.name) / "result with spaces"
        for name, text in {"PhoneAgent/App.swift": "synthetic source",
                           "Shared/Types.swift": "synthetic types",
                           "PhoneAgent/Resources/fixture.txt": "synthetic asset",
                           "PhoneAgent.xcodeproj/project.pbxproj": "synthetic project"}.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        subprocess.run(["git", "init", "-q", "--template=", str(self.root)], check=True)
        subprocess.run(["git", "-C", str(self.root), "-c", "user.name=Fixture", "-c",
                        "user.email=fixture@example.invalid", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
                        "commit", "-q", "--allow-empty", "-m", "synthetic fixture"], check=True)
        self.run_cli("create", check=True)
        self.expected_revision = (self.output / "source-revision.txt").read_text()

    def run_cli(self, operation, check=False):
        arguments = ["python3", str(SCRIPT), operation, str(self.root), str(self.output)]
        if operation == "check":
            arguments += ["--expected-revision", self.expected_revision]
        return subprocess.run(arguments,
                              capture_output=True, text=True, check=check)

    def test_unchanged_source_and_original_digest_algorithm(self):
        value = json.loads((self.output / "source-manifest.json").read_text())
        self.assertEqual(value["source_sha256"], "c225ee410f6b9881f591071f8405d48008755f5437d687dcd4dfc0e20355ee95")
        self.assertEqual(value["source_sha256"], manifest.source_digest(manifest.source_entries(self.root)))
        self.assertEqual(value["source_revision"], (self.output / "source-revision.txt").read_text())
        self.assertEqual(self.run_cli("check").returncode, 0)

    def test_added_production_file_rejects_old_manifest(self):
        old = manifest.source_entries(self.root)
        (self.root / "PhoneAgent/New.swift").write_text("new synthetic source")
        current = manifest.source_entries(self.root)
        # The former post-build loop would miss this exact mutation.
        self.assertFalse(any(current.get(name) != digest for name, digest in old.items()))
        result = self.run_cli("check")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('"added": ["PhoneAgent/New.swift"]', result.stderr)

    def test_removed_production_file_rejected(self):
        (self.root / "Shared/Types.swift").unlink()
        result = self.run_cli("check")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('"removed": ["Shared/Types.swift"]', result.stderr)

    def test_modified_source_rejected(self):
        (self.root / "PhoneAgent/App.swift").write_text("modified synthetic source")
        result = self.run_cli("check")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('"modified": ["PhoneAgent/App.swift"]', result.stderr)

    def test_resource_addition_also_rejected(self):
        (self.root / "PhoneAgent/Resources/another.txt").write_text("new asset")
        self.assertNotEqual(self.run_cli("check").returncode, 0)

    def test_project_signing_or_version_mutation_rejected(self):
        (self.root / "PhoneAgent.xcodeproj/project.pbxproj").write_text("changed synthetic project")
        self.assertNotEqual(self.run_cli("check").returncode, 0)

    def test_existing_build_artifact_exclusions_preserved(self):
        for name in ("PhoneAgent/build-test/out.swift", "firmware/managed_components/vendor.c", "Shared/__pycache__/cache.pyc"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("excluded synthetic artifact")
        self.assertEqual(self.run_cli("check").returncode, 0)

    def test_manifest_digest_corruption_rejected(self):
        path = self.output / "source-manifest.json"
        value = json.loads(path.read_text())
        value["files"]["PhoneAgent/App.swift"] = "0" * 64
        path.write_text(json.dumps(value))
        result = self.run_cli("check")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid source manifest digest", result.stderr)

    def test_manifest_revision_corruption_rejected(self):
        path = self.output / "source-manifest.json"
        value = json.loads(path.read_text())
        value["source_revision"] = "corrupt-revision"
        path.write_text(json.dumps(value))
        self.assertNotEqual(self.run_cli("check").returncode, 0)

    def test_compiler_revision_file_corruption_rejected(self):
        (self.output / "source-revision.txt").write_text("wrong-embedded-build-revision")
        self.assertNotEqual(self.run_cli("check").returncode, 0)

    def test_recreated_manifest_cannot_rebind_in_progress_build(self):
        (self.root / "PhoneAgent/App.swift").write_text("changed after compiler revision captured")
        self.run_cli("create", check=True)
        self.assertNotEqual(self.run_cli("check").returncode, 0)

    def test_check_without_captured_revision_rejected(self):
        result = subprocess.run(["python3", str(SCRIPT), "check", str(self.root), str(self.output)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_same_output_lock_rejects_before_create_or_build(self):
        lock = self.output / ".build-verified.lock"
        lock.mkdir()
        old_manifest = (self.output / "source-manifest.json").read_bytes()
        result = subprocess.run(["bash", str(SCRIPT.parent / "build-verified.sh"), "simulator", str(self.output)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(lock.is_dir())
        self.assertEqual((self.output / "source-manifest.json").read_bytes(), old_manifest)


if __name__ == "__main__":
    unittest.main()
