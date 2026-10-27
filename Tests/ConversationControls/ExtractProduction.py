#!/usr/bin/env python3
"""Whole VM methods and route closure; no substitutions inside production code."""
from pathlib import Path
import hashlib
import json
import sys


def member(text, signature):
    assert text.count(signature) == 1, signature
    start = text.index(signature)
    cursor = text.index("{", start) + 1
    depth = 1
    while depth:
        depth += (text[cursor] == "{") - (text[cursor] == "}")
        cursor += 1
    return text[start:cursor]


def declaration(text, signature):
    start = text.index(signature)
    end = text.index("\n", start)
    return member(text, signature) if "{" in text[start:end] else text[start:end]


root, target, destination = [Path(value).resolve() for value in sys.argv[1:]]
destination.mkdir(exist_ok=False)
vm = (root / "PhoneAgent/PhoneAgentViewModel.swift").read_text()
coordinator = (root / "PhoneAgent/Services/UnifiedConversationCoordinator.swift").read_text()
closure = member(vm, "        conversation.unifiedRoute = { [weak self] input in")
pending_callback = member(vm, "        conversation.pendingTaskSubmission = { [weak self] in")
members = {
    "routeBridge": "    func installRouteBridge() {\n" + pending_callback + "\n" + closure + "\n    }",
    "pendingTask": member(vm, "    func pendingTaskForConversation(_ conversationID: UUID) -> ConversationTaskSubmission?"),
    "taskContext": member(coordinator, "    func unifiedTaskContext(history messages: [AssistantMessage], question: String? = nil, originatingConversationID: UUID? = nil) -> String"),
    "actionHandler": member(coordinator, "    func handleConversationAction(_ route: ConversationRoute, messageID: UUID)"),
    "resume": member(vm, "    func resumeVoiceTask("),
    "manualBusy": declaration(vm, "    @Published var manualBusy ="),
    "calibrating": declaration(vm, "    @Published var calibrating ="),
    "pendingConsentStart": declaration(vm, "    private var pendingConsentStart ="),
}
if "    var conversationControlContext:" in vm:
    members["controlContext"] = member(vm, "    var conversationControlContext:")
template = (target / "Environment.swift").read_text()
assert template.count("// EXACT_PRODUCTION_MEMBERS") == 1
(destination / "Environment.swift").write_text(template.replace("// EXACT_PRODUCTION_MEMBERS", "\n".join(members.values())))
for name, value in members.items():
    (destination / (name + ".swift.txt")).write_text(value)
names = ["PhoneAgent/PhoneAgentViewModel.swift", "PhoneAgent/Services/UnifiedConversationCoordinator.swift", "Shared/AssistantConversationContext.swift"]
for name in names:
    p = destination / "current-source" / name
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes((root / name).read_bytes())
(destination / "extraction.json").write_text(json.dumps({
    "completeOriginalMethods": True, "methodSubstitutions": [],
    "methodSHA256": {name: hashlib.sha256(value.encode()).hexdigest() for name, value in members.items()},
    "wholeSourceSHA256": {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in names},
    "limits": "Extracted VM route closure, context/action/resume methods and interaction observers. Engine/queue/audio/router/consent are synthetic; flight opening fails immediately if reached and is tested by FlightSelection/CtripHandoff. Not full VM/UI/voice/model/phone acceptance.",
}, indent=2) + "\n")
print("ConversationControls: complete production methods and observers extracted without substitutions")
