#!/usr/bin/env python3
"""Destructive-cleanup safety checks, using disposable synthetic projects only."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[2] / "scripts/cleanup-build-artifacts.py"
spec = importlib.util.spec_from_file_location("build_retention", SCRIPT)
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)


class RetentionChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="build-retention-")
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name).resolve() / "project with spaces"
        (self.project / "PhoneAgent.xcodeproj").mkdir(parents=True)
        (self.project / "PhoneAgent.xcodeproj/project.pbxproj").write_text("fixture")
        self.root = self.project / "output"
        self.root.mkdir()
        self.now = time.time()

    def artifact(self, name, age=10, platform="iphoneos", bundle="com.fixture.phone", valid=True,
                 project="PhoneAgent.xcodeproj"):
        derived = self.root / name / "build"
        app = derived / "Build/Products" / ("Debug-" + platform) / "PhoneAgent.app"
        app.mkdir(parents=True)
        info = {"CFBundleIdentifier": bundle, "CFBundleVersion": name, "DTPlatformName": platform}
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        (app / "binary").write_bytes(b"x" * 8192)
        (derived / "SDKExplicitPrecompiledModules").mkdir()
        (derived / "SDKExplicitPrecompiledModules/module.pcm").write_bytes(b"c" * 8192)
        if valid:
            (derived / "info.plist").write_bytes(plistlib.dumps({
                "WorkspacePath": str(self.project / project)}))
        for p in sorted(derived.rglob("*"), reverse=True) + [derived]:
            os.utime(p, (self.now - age * 3600,) * 2)
        return derived

    def options(self, **values):
        defaults = dict(root=self.root, log_dir=self.project / "logs", protect=[], apply=True,
                        budget_gib=0.000001, keep=2, min_age_hours=2, max_age_hours=48,
                        download_caches=False, chrome_clones=False, test_temp_caches=False)
        defaults.update(values)
        return argparse.Namespace(**defaults)

    def test_latest_two_per_platform_and_bundle_are_retained(self):
        oldest = self.artifact("old", age=30)
        self.artifact("recent", age=20)
        self.artifact("newest", age=10)
        simulator = self.artifact("sim", age=40, platform="iphonesimulator")
        signed = self.artifact("other-id", age=40, bundle="com.fixture.signed")
        selected, kept, _ = cleanup.plan_cleanup(self.root, cleanup.discover(self.root), set(),
                                                now=self.now, budget=0)
        self.assertEqual([item["path"] for item in selected], [oldest])
        self.assertTrue(all(str(p) in {r["path"] for r in kept} for p in (simulator, signed)))

    def test_unique_native_test_session_ids_do_not_accumulate_forever(self):
        old = self.artifact('runner-old', age=30, bundle='com.fixture.session.old', project='NativePanelRunner.xcodeproj')
        self.artifact('runner-recent', age=20, bundle='com.fixture.session.recent', project='NativePanelRunner.xcodeproj')
        self.artifact('runner-new', age=10, bundle='com.fixture.session.new', project='NativePanelRunner.xcodeproj')
        selected, _, _ = cleanup.plan_cleanup(self.root, cleanup.discover(self.root), set(), now=self.now, budget=0)
        self.assertEqual([r['path'] for r in selected], [old])

    def test_native_controller_releases_lease_without_swallowing_session_failure(self):
        path = SCRIPT.parents[1] / 'Tools/NativeAcceptance/run-controller.py'
        other = importlib.util.spec_from_file_location('retention_controller_fixture', path)
        controller = importlib.util.module_from_spec(other)
        other.loader.exec_module(controller)
        out = self.root / 'controller'
        out.mkdir()
        with mock.patch.object(controller.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run:
            with self.assertRaisesRegex(RuntimeError, 'fixture session failed'):
                with controller.retention_lease(out):
                    self.assertTrue((out / '.build-retention.lock/owner.json').exists())
                    raise RuntimeError('fixture session failed')
        self.assertFalse((out / '.build-retention.lock').exists())
        self.assertIn('--protect', run.call_args.args[0])

    def test_post_build_cleanup_preserves_build_and_check_exit_codes(self):
        import shutil
        scripts = self.project / 'scripts'
        scripts.mkdir()
        shutil.copy2(SCRIPT.parent / 'build-verified.sh', scripts / 'build-verified.sh')
        (scripts / 'source-manifest.py').write_text(
            "import os,sys\nfrom pathlib import Path\n"
            "out=Path(sys.argv[3])\n"
            "if sys.argv[1]=='create': (out/'source-revision.txt').write_text('fixture-revision')\n"
            "else: sys.exit(int(os.environ['RETENTION_FIXTURE_CHECK_EXIT']))\n")
        capture = self.project / 'cleanup-arguments.json'
        (scripts / 'cleanup-build-artifacts.py').write_text(
            "import os,sys,json\nfrom pathlib import Path\n"
            "Path(os.environ['RETENTION_FIXTURE_CAPTURE']).write_text(json.dumps(sys.argv[1:]))\n"
            "sys.exit(2)\n")
        bin_dir = self.project / 'bin'
        bin_dir.mkdir()
        compiler = bin_dir / 'xcodebuild'
        compiler.write_text('#!/bin/sh\nexit "$RETENTION_FIXTURE_BUILD_EXIT"\n')
        compiler.chmod(0o700)
        for build_exit, check_exit, expected in [(23, 0, 23), (0, 19, 19), (0, 0, 0)]:
            output = self.root / ('fixture-%s-%s' % (build_exit, check_exit))
            env = dict(os.environ, PATH=str(bin_dir) + ':' + os.environ['PATH'],
                       RETENTION_FIXTURE_BUILD_EXIT=str(build_exit),
                       RETENTION_FIXTURE_CHECK_EXIT=str(check_exit), RETENTION_FIXTURE_CAPTURE=str(capture))
            result = subprocess.run(['bash', str(scripts / 'build-verified.sh'), 'simulator', str(output)],
                                    env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, expected, result.stderr)
            self.assertFalse((output / '.build-verified.lock').exists())
            self.assertEqual(json.loads(capture.read_text()), ['--apply', '--protect', str(output)])

    def test_active_parent_and_explicit_protection_override_budget(self):
        active = self.artifact("active", age=100)
        other = self.artifact("protected", age=90)
        self.artifact("newest-1", age=4)
        self.artifact("newest-2", age=3)
        selected, _, _ = cleanup.plan_cleanup(self.root, cleanup.discover(self.root),
                                              {active.parent}, [other], now=self.now, budget=0)
        self.assertEqual(selected, [])

    def test_pin_and_build_locks_override_budget(self):
        for index, marker in enumerate((".keep-build", ".build-verified.lock", ".build-retention.lock")):
            p = self.artifact("pinned-" + str(index), age=100)
            (p.parent / marker).mkdir()
        self.artifact("new-1", age=4)
        self.artifact("new-2", age=3)
        self.assertEqual(cleanup.plan_cleanup(self.root, cleanup.discover(self.root), set(),
                                              now=self.now, budget=0)[0], [])

    def activity_fixture(self, opened=(), command=""):
        ps = subprocess.CompletedProcess([], 0, stdout='999999 1 ' + command + '\n', stderr='')
        with mock.patch.object(cleanup.subprocess, 'run', return_value=ps), \
                mock.patch.object(cleanup, 'inspect_open_files', return_value=[(999999, p) for p in opened]):
            return cleanup.snapshot_activity(self.root)[0]

    def test_open_result_protects_only_its_nested_session(self):
        old = self.artifact('shared/old', age=60)
        current = self.artifact('shared/current', age=10)
        self.artifact('latest-1', age=4)
        self.artifact('latest-2', age=3)
        active = self.activity_fixture([current.parent / 'operator-session.xcresult/Staging/log.txt'])
        self.assertEqual(active, {current.parent})
        selected, _, _ = cleanup.plan_cleanup(self.root, cleanup.discover(self.root), active,
                                              now=self.now, budget=0)
        self.assertEqual([r['path'] for r in selected], [old])

    def test_system_reader_of_unrelated_document_does_not_pin_sibling_builds(self):
        old = self.artifact('shared/old', age=60)
        self.artifact('latest-1', age=4)
        self.artifact('latest-2', age=3)
        document = self.root / 'shared/observations/state.json'
        active = self.activity_fixture([document])
        self.assertEqual(active, {document})
        selected, _, _ = cleanup.plan_cleanup(self.root, cleanup.discover(self.root), active,
                                              now=self.now, budget=0)
        self.assertEqual([r['path'] for r in selected], [old])

    def test_command_paths_with_spaces_protect_current_source_and_build(self):
        old = self.artifact('shared/old', age=60)
        current = self.artifact('shared/current session', age=10)
        self.artifact('latest-1', age=4)
        self.artifact('latest-2', age=3)
        active = self.activity_fixture(command='bash ' + str(current.parent / 'source/Tests/run.sh'))
        self.assertEqual(active, {current.parent})
        selected, _, _ = cleanup.plan_cleanup(self.root, cleanup.discover(self.root), active,
                                              now=self.now, budget=0)
        self.assertEqual([r['path'] for r in selected], [old])

    def test_multiple_command_sessions_and_direct_open_binary_are_protected(self):
        first = self.artifact('shared/first', age=20)
        second = self.artifact('shared/second', age=10)
        active = self.activity_fixture(command='xcodebuild -derivedDataPath ' + str(first)
                                       + ' -resultBundlePath ' + str(second.parent / 'result.xcresult'))
        self.assertEqual(active, {first.parent, second.parent})
        binary = first / 'Build/Products/Debug-iphoneos/PhoneAgent.app/binary'
        self.assertEqual(self.activity_fixture([binary]), {first.parent})

    def test_open_shared_directory_remains_conservatively_protected(self):
        old = self.artifact('shared/old', age=60)
        shared = old.parent.parent
        active = self.activity_fixture([shared])
        self.assertEqual(active, {shared})
        self.assertEqual(cleanup.plan_cleanup(self.root, cleanup.discover(self.root), active,
                                              now=self.now, budget=0)[0], [])

    def test_direct_derived_root_does_not_make_output_a_session(self):
        old = self.artifact('old', age=60)
        old.rename(self.root / 'direct-derived')
        sessions = cleanup.activity_sessions(self.root)
        self.assertIn(self.root / 'direct-derived', sessions)
        self.assertNotIn(self.root, sessions)

    def test_service_script_keeps_its_nested_runner_between_requests(self):
        build = self.artifact('service/runner', age=60)
        script = build.parent.parent / 'server.py'
        script.write_text('# fixture service')
        active = self.activity_fixture(command='python3 ' + str(script))
        self.assertEqual(active, {script.parent})
        self.assertEqual(cleanup.plan_cleanup(self.root, cleanup.discover(self.root), active,
                                              now=self.now, budget=0)[0], [])

    def test_storage_settings_directory_scan_does_not_protect_whole_output(self):
        build = self.artifact('old', age=60)
        active = self.activity_fixture([self.root], command=cleanup.STORAGE_SCANNER)
        self.assertEqual(active, set())
        binary = build / 'Build/Products/Debug-iphoneos/PhoneAgent.app/binary'
        self.assertEqual(self.activity_fixture([binary], command=cleanup.STORAGE_SCANNER),
                         {build.parent})

    def test_later_candidate_is_rechecked_after_prior_deletion(self):
        first = self.artifact('first', age=60)
        later = self.artifact('later', age=50)
        self.artifact('latest-1', age=4)
        self.artifact('latest-2', age=3)
        with mock.patch.object(cleanup, 'snapshot_activity', side_effect=[
                (set(), []), (set(), []), ({later.parent}, [])]):
            result = cleanup.run(self.options())
        self.assertFalse((first / 'Build').exists())
        self.assertTrue((later / 'Build').exists())
        self.assertIn(str(later), result['skipped_after_recheck'])

    def test_recent_grace_and_age_based_reclamation(self):
        recent = self.artifact("in-grace", age=1)
        old = self.artifact("expired", age=60)
        self.artifact("new-1", age=0.5)
        self.artifact("new-2", age=0.2)
        selected, _, _ = cleanup.plan_cleanup(self.root, cleanup.discover(self.root), set(),
                                              now=self.now, budget=100 * cleanup.GIB)
        self.assertEqual([r["path"] for r in selected], [old])
        self.assertTrue((recent / "Build").is_dir())

    def test_sources_evidence_and_arbitrary_build_directory_survive_apply(self):
        old = self.artifact("old", age=60)
        self.artifact("new-1", age=4)
        self.artifact("new-2", age=3)
        evidence = old.parent / "verification.json"
        evidence.write_text('{"result":"keep"}')
        source = old.parent / "source/App.swift"
        source.parent.mkdir()
        source.write_text("precious source")
        user_build = self.artifact("not-xcode-metadata", age=100, valid=False)
        with mock.patch.object(cleanup, "snapshot_activity", return_value=(set(), [])):
            result = cleanup.run(self.options())
        self.assertGreater(result["deleted_bytes"], 0)
        self.assertFalse((old / "Build").exists())
        self.assertFalse((old / "SDKExplicitPrecompiledModules").exists())
        self.assertTrue((old / "info.plist").exists())
        self.assertEqual(source.read_text(), "precious source")
        self.assertEqual(json.loads(evidence.read_text()), {"result": "keep"})
        self.assertTrue((user_build / "Build").exists())

    def test_dry_run_does_not_remove_artifacts(self):
        old = self.artifact("old", age=60)
        self.artifact("new-1", age=4)
        self.artifact("new-2", age=3)
        with mock.patch.object(cleanup, "snapshot_activity", return_value=(set(), [])):
            result = cleanup.run(self.options(apply=False))
        self.assertEqual(result["deleted_bytes"], 0)
        self.assertTrue((old / "Build").exists())

    def test_symlinked_roots_and_children_are_never_deleted(self):
        old = self.artifact("old", age=60)
        outside = Path(self.temp.name) / "personal"
        outside.mkdir()
        (outside / "data").write_text("keep me")
        (old / "ModuleCache.noindex").symlink_to(outside, target_is_directory=True)
        link = self.project / "linked-output"
        link.symlink_to(self.root, target_is_directory=True)
        self.assertFalse(cleanup.safe_child(self.root, old, old / "ModuleCache.noindex"))
        with self.assertRaises(RuntimeError):
            cleanup.run(self.options(root=link))
        with mock.patch.object(cleanup, "snapshot_activity", return_value=(set(), [])):
            cleanup.run(self.options())
        self.assertEqual((outside / "data").read_text(), "keep me")

    def test_inspection_failure_is_fail_closed(self):
        old = self.artifact("old", age=60)
        with mock.patch.object(cleanup, "snapshot_activity", side_effect=RuntimeError("fixture failure")):
            with self.assertRaises(RuntimeError):
                cleanup.run(self.options())
        self.assertTrue((old / "Build").is_dir())

    def test_new_session_seen_during_recheck_is_preserved(self):
        old = self.artifact("old", age=60)
        self.artifact("new-1", age=4)
        self.artifact("new-2", age=3)
        with mock.patch.object(cleanup, "snapshot_activity", side_effect=[(set(), []), ({old.parent}, [])]):
            result = cleanup.run(self.options())
        self.assertEqual(result["deleted_bytes"], 0)
        self.assertIn(str(old), result["skipped_after_recheck"])
        self.assertTrue((old / "Build").is_dir())

    def test_sdk_cache_without_products_can_expire(self):
        old = self.artifact("orphan", age=60)
        import shutil
        shutil.rmtree(old / "Build")
        os.utime(old, (self.now - 60 * 3600,) * 2)
        selected, _, _ = cleanup.plan_cleanup(self.root, cleanup.discover(self.root), set(),
                                              now=self.now, budget=100 * cleanup.GIB)
        self.assertEqual([r["path"] for r in selected], [old])

    def test_package_manager_in_use_skips_download_cleanup(self):
        with mock.patch.object(cleanup, "allocated", return_value=10 * cleanup.GIB) as size:
            result = cleanup.cleanup_downloads(self.project, ["node /npm/bin/npx-cli.js run fixture"], True)
        self.assertIn("package manager active", result[0]["reason"])
        size.assert_not_called()

    def test_only_old_idle_verified_chrome_clones_are_removed(self):
        base = self.project / "X/com.google.Chrome.code_sign_clone"
        base.mkdir(parents=True)
        clones = []
        for name, age, bundle_id in [('old', 20, 'com.google.Chrome'),
                                     ('open', 15, 'com.google.Chrome'),
                                     ('wrong', 12, 'com.fixture.personal'),
                                     ('recent', 1, 'com.google.Chrome'),
                                     ('newest', 0.5, 'com.google.Chrome')]:
            p = base / ('code_sign_clone.' + name)
            info = p / 'Google Chrome.app.bundle/Contents/Info.plist'
            info.parent.mkdir(parents=True)
            info.write_bytes(plistlib.dumps({'CFBundleIdentifier': bundle_id}))
            os.utime(p, (self.now - age * 3600,) * 2)
            clones.append(p)
        result = cleanup.cleanup_chrome_clones(base, [clones[1] / 'open-binary'], True, self.now)
        self.assertEqual([x['path'] for x in result], [str(clones[0])])
        self.assertFalse(clones[0].exists())
        self.assertTrue(all(p.exists() for p in clones[1:]))

    def test_old_failed_test_cache_removed_but_evidence_and_live_cache_survive(self):
        temp = self.project / 'temp'
        temp.mkdir()
        workspaces = []
        for name in ['pdf-preflight-checks.old', 'context-lease-checks.active', 'personal-files']:
            work = temp / name
            cache = work / 'module-cache'
            cache.mkdir(parents=True)
            (cache / 'fixture.pcm').write_bytes(b'cache')
            (work / 'result.json').write_text('{"failure":"preserve"}')
            os.utime(cache, (self.now - 5 * 3600,) * 2)
            os.utime(work, (self.now - 5 * 3600,) * 2)
            workspaces.append(work)
        result = cleanup.cleanup_test_caches(temp, ['swiftc ' + str(workspaces[1])], [], True, self.now)
        self.assertEqual([x['path'] for x in result], [str(workspaces[0] / 'module-cache')])
        self.assertTrue((workspaces[0] / 'result.json').exists())
        self.assertTrue(all((p / 'module-cache').exists() for p in workspaces[1:]))


if __name__ == "__main__":
    unittest.main()
