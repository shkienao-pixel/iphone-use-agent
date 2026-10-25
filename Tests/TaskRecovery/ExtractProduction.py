#!/usr/bin/env python3
"""Complete selected-task recovery controller members, with no body substitutions."""
from pathlib import Path
import hashlib
import json
import sys

root, destination = [Path(p).resolve() for p in sys.argv[1:]]
destination.mkdir(exist_ok=False)
text = (root / "PhoneAgent/PhoneAgentViewModel.swift").read_text()

def member(signature):
    assert text.count(signature) == 1, signature
    start = text.index(signature)
    cursor = text.index("{", start) + 1
    depth = 1
    while depth:
        depth += (text[cursor] == "{") - (text[cursor] == "}")
        cursor += 1
    return text[start:cursor]

signatures = [
    "    var taskRecoveryBusy:", "    func recoverableTask(",
    "    @discardableResult\n    func retryTask(", "    @discardableResult\n    func continueTask(",
    "    private func recoverTask(",
]
members = [member(value) for value in signatures]
native_source = (root / "PhoneAgent/Services/BackgroundTaskExecution.swift").read_text()
a = native_source.index("    @discardableResult func recoverBackgroundTask(")
b = native_source.index("{", a) + 1
depth = 1
while depth:
    depth += (native_source[b] == "{") - (native_source[b] == "}"); b += 1
members.append(native_source[a:b])

template = (root / "Tests/TaskRecovery/Environment.swift").read_text()
assert template.count("// EXACT_RECOVERY_MEMBERS") == 1
(destination / "Controller.swift").write_text(template.replace("// EXACT_RECOVERY_MEMBERS", "\n".join(members)))
engine = (root / "PhoneAgent/Services/AgentEngine.swift").read_text()
assert engine.count("import UIKit") == 1
(destination / "Engine.swift").write_text(engine.replace("import UIKit", "import CoreGraphics"))
lease = (root / "PhoneAgent/Services/WorkflowObservationLease.swift").read_text()
(destination / "LeaseFailure.swift").write_text("import Foundation\n" + lease[lease.index("struct WorkflowLeaseFailure:"):lease.index("/// Pixel recognition reuse only.")])
tools = (root / "PhoneAgent/Services/SystemTools.swift").read_text()

def tool_member(signature):
    assert tools.count(signature) == 1, signature
    start = tools.index(signature)
    cursor = tools.index("{", start) + 1
    depth = 1
    while depth:
        depth += (tools[cursor] == "{") - (tools[cursor] == "}")
        cursor += 1
    return tools[start:cursor]

canonical_start = tools.index("        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]")
guard_start = tools.index("        if let receipt = receipts[key]", canonical_start)
guard_end = tools.index("        let id = UUID()", guard_start)
canonical = tools[canonical_start:guard_start]
receipt_guards = tools[guard_start:guard_end]
readability = tool_member("        if request.operation.writes {\n            guard readable")
unresolved = tool_member("    func hasUnresolvedWrite(")
receipt = tool_member("    private struct Receipt:")
policy = '''import Foundation
import CryptoKit

@MainActor final class RecoveryReceiptPolicy {
RECEIPT
    private var receipts: [String: Receipt] = [:]
    var readable = true
    var error = "Unreadable receipt fixture"
UNRESOLVED
    func key(for request: SystemToolRequest, taskID: UUID) throws -> String {
CANONICAL
        return key
    }
    func check(_ request: SystemToolRequest, taskID: UUID) throws -> String? {
        try request.validate()
READABILITY
        let key = try key(for: request, taskID: taskID)
GUARDS
        return nil
    }
    func seed(_ request: SystemToolRequest, taskID: UUID, state: String, result: String? = nil) throws {
        receipts[try key(for: request, taskID: taskID)] = Receipt(id: UUID(), state: state, result: result)
    }
    func seedRaw(_ key: String) { receipts[key] = Receipt(id: UUID(), state: "pending", result: nil) }
    var receiptCount: Int { receipts.count }
}
'''
for name, body in [("RECEIPT", receipt), ("UNRESOLVED", unresolved), ("CANONICAL", canonical), ("READABILITY", readability), ("GUARDS", receipt_guards)]:
    policy = policy.replace(name, body)
(destination / "ReceiptPolicy.swift").write_text(policy)
(destination / "extraction.json").write_text(json.dumps({
    "controllerMethodSubstitutions": [],
    "controllerSHA256": [hashlib.sha256(value.encode()).hexdigest() for value in members],
    "engineSubstitutions": ["UIKit import replaced with CoreGraphics for offline platform"],
    "receiptDecisionSubstitutions": [],
    "receiptDecisionSHA256": hashlib.sha256((readability + canonical + receipt_guards + unresolved).encode()).hexdigest(),
    "receiptScope": "Exact canonical key generation, readable guard, existing-receipt decision and same-task pending-write guard extracted from production SystemTools.execute; harness seeds receipt data and invokes only this pure decision slice, never OS authorization or writes.",
    "scope": "Actual recovery VM methods, full actual AgentEngine, actual history and queue stores. Model, capture, audio/UI state and BLE are synthetic; no phone or provider acceptance."
}, indent=2))
