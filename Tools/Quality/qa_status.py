#!/usr/bin/env python3
"""Validate curated evidence; historical checks are not current App acceptance."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCOPES = {"offline_logic", "simulator_native_ui", "simulator_presentation", "simulator_os_notification",
          "real_model_native", "official_plan_inference", "offline_transport", "preservation"}


def local_file(name):
    path = (ROOT / name).resolve()
    if not path.is_relative_to(ROOT) or not path.is_file():
        raise ValueError("Missing or outside-workspace evidence: " + name)
    return path


def read_json(name):
    path = local_file(name)
    if path.stat().st_size > 25_000_000:
        raise ValueError("Evidence JSON exceeds review limit: " + name)
    return json.loads(path.read_text())


def proof(check):
    value = read_json(check["artifact"])
    for key in check["at"]:
        value = value[key]
    expected = check["equals"]
    # JSON true must never satisfy an integer count such as one successful round.
    return type(value) is type(expected) and value == expected


def evaluate(catalog, revision):
    if catalog.get("version") != 1 or not catalog.get("cases"):
        raise ValueError("Unsupported or empty QA catalog")
    ids = set()
    result = []
    for case in catalog["cases"]:
        identity = case["id"]
        if identity in ids:
            raise ValueError("Duplicate case ID: " + identity)
        ids.add(identity)
        if case["priority"] not in {"P0", "P1", "P2"} or case["required_scope"] not in SCOPES:
            raise ValueError("Invalid priority or required scope: " + identity)
        if type(case["required_rounds"]) is not int or case["required_rounds"] < 1 or not case["oracle"]:
            raise ValueError("Missing positive round count or user outcome: " + identity)
        binding = case.get("source_binding", "app")
        if binding not in {"app", "components"}:
            raise ValueError("Unknown source binding: " + identity)
        accepted, observations = False, []
        for observation in case.get("observations", []):
            if observation["scope"] not in SCOPES or observation["verdict"] not in {"pass", "partial", "blocked"}:
                raise ValueError("Invalid observation: " + identity)
            if type(observation["rounds"]) is not int or observation["rounds"] < 0:
                raise ValueError("Invalid observed rounds: " + identity)
            checks = observation.get("proofs", [])
            results = [proof(check) for check in checks]
            if observation["verdict"] == "pass" and (not checks or not all(results)):
                raise ValueError("A passing observation contradicts its evidence: " + identity)
            hashes = observation.get("component_hashes", {})
            if binding == "components":
                same_source = bool(hashes) and all(hashlib.sha256(local_file(name).read_bytes()).hexdigest() == digest
                                                   for name, digest in hashes.items())
            else:
                same_source = bool(revision) and observation.get("source_revision") == revision
            sufficient = (observation["verdict"] == "pass" and same_source and bool(checks) and all(results)
                          and observation["scope"] == case["required_scope"]
                          and observation["rounds"] >= case["required_rounds"])
            accepted = accepted or sufficient
            observations.append({"verdict": observation["verdict"], "scope": observation["scope"],
                "rounds": observation["rounds"], "proofs_match": all(results) if checks else False,
                "source_matches": same_source, "satisfies_case": sufficient})
        result.append({"id": identity, "title": case["title"], "priority": case["priority"],
            "accepted_for_requested_source": accepted, "required_scope": case["required_scope"],
            "required_rounds": case["required_rounds"], "observations": observations, "gaps": case.get("gaps", [])})
    incomplete = [row["id"] for row in result if row["priority"] in {"P0", "P1"} and not row["accepted_for_requested_source"]]
    return {"catalog_valid": True, "requested_source_revision": revision,
            "acceptance_evaluated": bool(revision), "acceptance_ready": bool(revision) and not incomplete,
            "critical_incomplete": incomplete, "cases": result,
            "meaning": "Only curated scope/source/round/proof checks. Raw UI, interface and tool receipts remain necessary; catalog validation is not product acceptance."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", default="Tests/Acceptance/catalog.json")
    parser.add_argument("--source-revision")
    parser.add_argument("--require-acceptance", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.require_acceptance and not args.source_revision:
        parser.error("--require-acceptance needs the actual build's --source-revision")
    try:
        report = evaluate(read_json(args.catalog), args.source_revision)
    except (OSError, ValueError, TypeError, KeyError, IndexError) as error:
        print("INVALID QA EVIDENCE: " + str(error))
        return 1
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print("Catalog valid; " + str(len(report["cases"])) + " user journeys. This is not a product-pass count.")
    print("Acceptance: " + ("READY" if report["acceptance_ready"] else "NOT PROVEN"))
    print("Incomplete P0/P1: " + ", ".join(report["critical_incomplete"]))
    return 2 if args.require_acceptance and not report["acceptance_ready"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
