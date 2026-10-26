#!/usr/bin/env python3
"""Exact controller methods/callbacks with explicit synthetic dependencies."""
from pathlib import Path
import hashlib
import json
import sys


def member(text, signature):
    assert text.count(signature) == 1, signature
    a = text.index(signature); b = text.index("{", a) + 1; depth = 1
    while depth:
        depth += (text[b] == "{") - (text[b] == "}"); b += 1
    return text[a:b]


def field(text, signature):
    a = text.index(signature); b = text.index("\n", a)
    return member(text, signature) if "{" in text[a:b] else text[a:b]


root, target, output = [Path(value).resolve() for value in sys.argv[1:]]
output.mkdir(exist_ok=False)
vm = (root / "PhoneAgent/PhoneAgentViewModel.swift").read_text()
coordinator = (root / "PhoneAgent/Services/UnifiedConversationCoordinator.swift").read_text()
members = {
    "focus": field(vm, "    var unifiedFocusedTaskID:"),
    "pending": field(vm, "    var pendingConversationTask:"),
    "pendingConsent": field(vm, "    private var pendingConsentStart ="),
    "pendingScope": member(vm, "    func pendingTaskForConversation(_ conversationID: UUID) -> ConversationTaskSubmission?"),
    "context": member(coordinator, "    func unifiedTaskContext(history messages: [AssistantMessage], question: String? = nil) -> String"),
}
for signature in ["    private var automaticPreparationConversationTaskID:", "    private var pendingConsentConversationTask:"]:
    if signature in vm:
        members[signature.split()[2].rstrip(":")] = field(vm, signature)
for name, signature in {
    "start": "    @discardableResult\n    func startAgent(", "prepare": "    func prepareAutomatically(",
    "cancelPrepare": "    func cancelAutomaticPreparation(", "requestConsent": "    func requestConsent()",
    "acceptConsent": "    func acceptConsent()", "declineConsent": "    func declineConsent()",
    "stop": "    func stop()", "stopWithConversationControl": "    func stop(cancelConversation: Bool)", "pause": "    func pauseTask(",
    "cancelVoice": "    private func cancelVoicePreparation(",
}.items():
    members[name] = member(vm, signature)
record = member(vm, "        engine.onRecord = { [weak self] record in")
persistence = member(vm, "        engine.persistRecord = { [weak self] record in")
context = member(vm, "        conversation.taskContext = { [weak self] in")
routing_context = member(vm, "        conversation.routingTaskContext = { [weak self] question, history in") if "        conversation.routingTaskContext = {" in vm else ""
members["installCallbacks"] = "    func installCallbacks() {\n" + persistence + "\n" + record + "\n" + context + "\n" + routing_context + "\n    }"
modern = "ConversationTaskSubmission?" in members["pending"]
adapter = """
    @discardableResult
    func submitForChecks(id: UUID, conversationID: UUID, messageID: UUID, text: String, reference: String = "") -> Bool {
        goal = text
        ADAPTER_START
    }
    var consentPendingForChecks: Bool { pendingConsentStart }
    var pendingForChecks: Bool { pendingConversationTask != nil }
"""
if modern:
    start = "let submission = ConversationTaskSubmission(taskID: id, conversationID: conversationID, messageID: messageID, goal: text, reference: reference)\n        pendingConversationTask = submission\n        return startAgent(conversationTask: submission)"
else:
    start = "pendingConversationTask = (messageID, text)\n        let started = startAgent()\n        if !started && !preparingAutomatically { pendingConversationTask = nil }\n        return started"
adapter = adapter.replace("ADAPTER_START", start)
template = (target / "Environment.swift").read_text()
assert template.count("// EXACT_CONTROLLER_MEMBERS") == 1
(output / "OwnershipEnvironment.swift").write_text(template.replace("// EXACT_CONTROLLER_MEMBERS", "\n".join(members.values()) + adapter))
boundaries = (root / "Tests/AssistantConversation/Environment.swift").read_text()
boundaries = boundaries.replace("struct PhoneTaskRecord {", "struct PhoneTaskRecord {\n    var executionLane: String? = nil")
boundaries = boundaries.replace("enum TaskOutcome { case completed, interrupted", "enum TaskOutcome: String { case completed, interrupted")
boundaries = boundaries.replace("struct ScreenFrame { var capturedAt = Date(); var jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9]) }", "struct ScreenFrame { var capturedAt = Date(); var jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9]); var fullDisplay = true }")
boundaries = boundaries.replace("enum PrivacyConsent {", "@MainActor enum PrivacyConsent {\n    static var approved = true\n    static func grant(_ settings: AgentSettings) { approved = true }")
# Adapt the complete synthetic boundary member, rather than silently matching a
# specific old body. AssistantConversation's fixture now exposes `permitted`;
# this suite intentionally drives its own `approved` switch. Production
# controller methods above remain byte-for-byte unchanged.
allowed_signature = "    static func allowed(_ settings: AgentSettings) -> Bool"
allowed_member = member(boundaries, allowed_signature)
boundaries = boundaries.replace(allowed_member, allowed_signature + " { approved }", 1)
(output / "ModelBoundaries.swift").write_text(boundaries)
for name, value in members.items():
    (output / (name + ".swift.txt")).write_text(value)
sources = ["PhoneAgent/PhoneAgentViewModel.swift", "PhoneAgent/Services/UnifiedConversationCoordinator.swift", "PhoneAgent/Services/AssistantConversation.swift", "Shared/AssistantConversationContext.swift"]
for name in sources:
    q = output / "current-source" / name; q.parent.mkdir(parents=True, exist_ok=True); q.write_bytes((root / name).read_bytes())
(output / "extraction.json").write_text(json.dumps({
    "completeMethods": True, "methodSubstitutions": [],
    "methodSHA256": {name: hashlib.sha256(value.encode()).hexdigest() for name, value in members.items()},
    "sourceSHA256": {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in sources},
    "entryAdapter": "Live entry passes reserved task/chat/message identity" if modern else "Baseline entry passes its original message/goal tuple",
    "scaffoldChanges": ["TaskOutcome String rawValue", "ScreenFrame fullDisplay", "controllable synthetic consent", "baseline/new submission entry adapter outside production methods"],
    "limits": "Actual conversation/store lifecycle and unchanged extracted start/preparation/consent/cancel/record/context/focus logic. Engine, readiness, settings UI, capture, BLE and audio are synthetic. Not full VM/UI/hardware/model/phone acceptance.",
}, indent=2) + "\n")
print("ConversationTaskOwnership: complete controller methods/callbacks extracted without substitutions")
