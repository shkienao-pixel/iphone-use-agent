#!/usr/bin/env python3
"""Reproducible offline verification. No network, model, app or device calls."""
from pathlib import Path
import argparse
import collections
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

MODULE = Path(__file__).resolve().parents[1]


def source_manifest():
    result = {}
    for path in sorted(MODULE.rglob("*")):
        relative = path.relative_to(MODULE)
        if any(part in (".build", ".swiftpm", "verification", "__pycache__") for part in relative.parts):
            continue
        if path.is_file():
            result[str(relative)] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def parse_xctest(log):
    started = re.findall(r"^Test Case '([^']+)' started\.$", log, re.M)
    outcomes = re.findall(r"^Test Case '([^']+)' (passed|failed|skipped) ", log, re.M)
    summary = re.search(r"Test Suite 'All tests' (passed|failed) at[^\n]*\n\s*Executed (\d+) tests?, with (\d+) failures?", log)
    counts = collections.Counter(state for _, state in outcomes)
    complete = bool(summary) and len(started) > 0 and len(started) == len(set(started))
    complete = complete and collections.Counter(started) == collections.Counter(name for name, _ in outcomes)
    complete = complete and int(summary[2]) == len(started)
    return {
        "executed": len(started), "passed": counts["passed"], "failed_cases": counts["failed"],
        "skipped": counts["skipped"], "complete_report": complete,
        "reported_failure_assertions": int(summary[3]) if summary else None,
        "passed_all": bool(complete and summary[1] == "passed" and int(summary[3]) == 0 and counts["passed"] == len(started)),
        "cases": [{"id": name, "result": state} for name, state in outcomes],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", required=True, help="Fresh run name; existing evidence is never overwritten")
    parser.add_argument("--skill-validator", type=Path,
                        default=Path.home() / ".codex/skills/.system/skill-creator/scripts/quick_validate.py")
    parser.add_argument("--reference-images", type=Path, help="Explicit original JPEG directory; images are read only")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", args.label):
        parser.error("label must contain only lowercase letters, digits, hyphens or underscores")
    output = MODULE / "verification/runs" / args.label
    try:
        output.mkdir(parents=True, exist_ok=False)
    except FileExistsError:
        parser.error("run label already exists; choose a fresh label to preserve previous evidence")
    initial = source_manifest()
    (output / "source-manifest.json").write_text(json.dumps(initial, indent=2) + "\n")
    report = {"label": args.label, "passed": False, "source_manifest": "source-manifest.json",
              "device_actions": False, "model_evaluated": False, "core_runtime_integrated": False,
              "verification_scope": "offline_rules_source_boundaries_and_optional_reference_processing_not_live_acceptance"}

    def run(name, command, env=None):
        with (output / name).open("w") as stream:
            return subprocess.run(command, cwd=MODULE, stdout=stream, stderr=subprocess.STDOUT, env=env).returncode

    try:
        # Check package resolution before allowing the test command to build.
        package = json.loads(subprocess.check_output(["swift", "package", "--package-path", str(MODULE), "dump-package"], cwd=MODULE, text=True))
        if package["dependencies"]:
            raise RuntimeError("Offline verifier refuses external package dependencies")
        report["swift_exit_code"] = run("swift-test.log", ["swift", "test", "--package-path", str(MODULE)])
        tests = parse_xctest((output / "swift-test.log").read_text())
        report["tests"] = tests
        report["recovery_probe_build_exit_code"] = run("recovery-probe-build.log",
            ["swift", "build", "--package-path", str(MODULE), "--product", "wechat-draft-recovery-probe"])
        if report["recovery_probe_build_exit_code"] != 0:
            raise RuntimeError("Offline recovery probe did not build")
        binary_directory = Path(subprocess.check_output(["swift", "build", "--package-path", str(MODULE), "--show-bin-path"], text=True).strip().splitlines()[-1])
        binary = binary_directory / "wechat-draft-recovery-probe"
        if not binary.resolve().is_relative_to((MODULE / ".build").resolve()) or not binary.is_file():
            raise RuntimeError("Recovery probe is not the expected module-local executable")
        process_results = []
        def probe(mode, directory, *values):
            completed = subprocess.run([str(binary), mode, str(directory), *values], text=True, capture_output=True)
            with (output / "recovery-probe-processes.log").open("a") as log:
                log.write(json.dumps({"mode": mode, "values": values, "returncode": completed.returncode,
                                      "stdout": completed.stdout, "stderr": completed.stderr}) + "\n")
            if completed.returncode != 0:
                raise RuntimeError(f"Recovery probe {mode} failed; see recovery-probe-processes.log")
            return json.loads(completed.stdout)
        with tempfile.TemporaryDirectory(prefix="recovery-probe-", dir=MODULE / ".build") as temporary:
            for name, readback in (("unchanged", ""), ("partial", "he"), ("completed", "hello")):
                directory = Path(temporary) / name
                seeded = probe("seed", directory)
                resumed = probe("resume", directory, readback)
                expected = {"unchanged": "hold", "partial": "suffix_action_no_io", "completed": "verified_readback"}[name]
                passed = seeded["status"] == "intent_saved_no_io" and resumed["status"] == expected
                passed = passed and seeded["process_id"] != resumed["process_id"]
                passed = passed and seeded["device_input_performed"] is False and resumed["device_input_performed"] is False
                if name == "unchanged": passed = passed and resumed.get("reason") == "inputResultUncertain"
                if name == "partial": passed = passed and resumed.get("planned_text") == "llo"
                if name == "completed": passed = passed and resumed.get("text") == "hello"
                process_results.append({"case": name, "passed": passed, "seed": seeded, "resume": resumed})
            for name in ("missing", "pending", "normal"):
                directory = Path(temporary) / ("result-" + name)
                seeded = probe("seed-result", directory)
                resumed = probe("resume-result", directory, name)
                expected = "effect_verified" if name == "normal" else "effect_uncertain"
                passed = seeded["status"] == "effect_intent_saved_no_io" and resumed["status"] == expected
                passed = passed and seeded["process_id"] != resumed["process_id"] and resumed["operation_count"] == 1 and resumed["review_count"] == 1
                passed = passed and seeded["device_input_performed"] is False and resumed["device_input_performed"] is False
                if name == "missing": passed = passed and resumed.get("reason") == "recovered_unique_new_self_item_missing"
                if name == "pending": passed = passed and resumed.get("reason") == "recovered_new_item_pending"
                process_results.append({"case": "result-" + name, "passed": passed, "seed": seeded, "resume": resumed})
        (output / "recovery-processes.json").write_text(json.dumps(process_results, indent=2) + "\n")
        report["separate_process_recovery"] = {"passed": all(item["passed"] for item in process_results),
                                               "case_count": len(process_results), "evidence": "recovery-processes.json",
                                               "draft_case_count": 3, "result_case_count": 3,
                                               "input_source": "synthetic_semantic_fixtures_no_device_io"}
        if args.reference_images:
            report["reference_probe_build_exit_code"] = run("reference-probe-build.log", ["swift", "build", "--package-path", str(MODULE), "--product", "wechat-reference-ui-probe"])
            if report["reference_probe_build_exit_code"] != 0:
                raise RuntimeError("Reference probe did not build")
            reference_binary = binary_directory / "wechat-reference-ui-probe"
            with (output / "reference-ui.json").open("w") as result_file, (output / "reference-ui.log").open("w") as errors:
                reference_run = subprocess.run([str(reference_binary), str(args.reference_images)], stdout=result_file, stderr=errors)
            if reference_run.returncode != 0: raise RuntimeError("Reference probe failed; see reference-ui.log")
            reference = json.loads((output / "reference-ui.json").read_text())
            processed = reference["images_processed"] == 7 and reference["origin"] == "referenceImage" and reference["device_actions"] is False
            report["reference_ui"] = {"processing_passed": processed, "matched_pages": reference["matched_pages"],
                "all_expected_pages_matched": reference["all_expected_pages_matched"], "image_count": reference["images_processed"],
                "evidence": "reference-ui.json", "live_acceptance": False}
        environment = os.environ.copy()
        local_yaml = MODULE / ".build/skill-validation-python"
        environment["PYTHONPATH"] = str(local_yaml) + (os.pathsep + environment["PYTHONPATH"] if environment.get("PYTHONPATH") else "")
        report["skill_validator_exit_code"] = run("skill-format.log", [sys.executable, str(args.skill_validator), str(MODULE / "Skills/wechat-assistant")], env=environment)
        report["skill_format_passed"] = report["skill_validator_exit_code"] == 0
        report["isolation_exit_code"] = run("isolation.log", [sys.executable, str(MODULE / "scripts/check_isolation.py")])
        isolation = json.loads((MODULE / "verification/isolation.json").read_text())
        (output / "isolation.json").write_text(json.dumps(isolation, ensure_ascii=False, indent=2) + "\n")
        report["module_isolation_passed"] = report["isolation_exit_code"] == 0 and isolation["passed"]
        report["app_guide_integrated"] = isolation["app_integration_performed"]
        report["shared_workspace_baseline_unchanged"] = isolation["host_baseline_unchanged"]
        final = source_manifest()
        report["source_unchanged_during_verification"] = initial == final
        report["source_changed_files"] = [path for path in sorted(set(initial) | set(final)) if initial.get(path) != final.get(path)]
        report["passed"] = all((report["swift_exit_code"] == 0, tests["passed_all"], report["skill_format_passed"],
                                report["module_isolation_passed"], report["source_unchanged_during_verification"],
                                report["separate_process_recovery"]["passed"],
                                report.get("reference_ui", {}).get("processing_passed", True)))
        report["model_scenario_count"] = len(json.loads((MODULE / "Skills/wechat-assistant/references/behavior-evaluation.json").read_text())["cases"])
        report["toolchain"] = subprocess.check_output(["swift", "--version"], text=True).strip()
    except Exception as error:
        report["error"] = f"{type(error).__name__}: {error}"
    (output / "verification.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    # A failed run must never replace the pointer to the latest verified result.
    if report["passed"]:
        pointer = {"report": str((output / "verification.json").relative_to(MODULE)),
                   "report_sha256": hashlib.sha256((output / "verification.json").read_bytes()).hexdigest()}
        (MODULE / "verification/latest.json").write_text(json.dumps(pointer, indent=2) + "\n")
    print(json.dumps({key: report.get(key) for key in ("label", "passed", "source_unchanged_during_verification", "error")}, ensure_ascii=False))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
