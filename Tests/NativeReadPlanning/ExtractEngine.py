#!/usr/bin/env python3
"""Compile the actual native dispatch loop with offline boundary substitutes."""
from pathlib import Path
import hashlib, json, sys
root, output = map(Path, sys.argv[1:])
source = (root / "PhoneAgent/Services/AgentEngine.swift").read_text()
def method(signature):
    start = source.index(signature)
    opening = source.index("{", start)
    cursor, depth = opening + 1, 1
    while depth:
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[start:cursor]
methods = [method("    private struct PersistencePaused:"),
           method("    private func completionEvidence("),
           method("    private func finish(_ action:"),
           method("    @discardableResult private func executeTool("),
           method("    private func runTools(")]
prefix = (root / "Tests/NativeReadPlanning/EngineEnvironment.swift").read_text()
(output / "ProductionToolsLoop.swift").write_text(prefix + "\n" + "\n".join(methods) + "\n}\n")
(output / "engine-extraction.json").write_text(json.dumps({
    "sourceSHA256": hashlib.sha256(source.encode()).hexdigest(),
    "scope": "Exact production executeTool and runTools method bodies; offline field, metric, SDK and lifecycle substitutes only. No model, device or SDK calls."
}, indent=2) + "\n")
