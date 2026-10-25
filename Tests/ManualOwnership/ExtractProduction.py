#!/usr/bin/env python3
"""Extract whole current methods, with explicit synthetic surrounding services."""
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


def main():
    root, target, destination = map(lambda value: Path(value).resolve(), sys.argv[1:])
    assert not destination.exists(), "Preserve each extracted attempt"
    destination.mkdir(parents=True)
    vm = (root / "PhoneAgent/PhoneAgentViewModel.swift").read_text()
    ble = (root / "PhoneAgent/Services/BLETransport.swift").read_text()
    shared = (root / "Shared/AssistantConversationContext.swift").read_text()
    submission = member(shared, "struct ConversationTaskSubmission:")
    signatures = ["    func manualAction(allowsBackgroundScreen:",
                  "    @discardableResult\n    func pauseTask(", "    func stop()",
                  "    func stop(cancelConversation: Bool)",
                  "    private func cancelVoicePreparation("]
    members = [member(vm, signature) for signature in signatures]
    start = ble.index("    private lazy var releaseController =")
    end = ble.index("    var ready:", start)
    ble_members = [ble[start:end], member(ble, "    @discardableResult func release(")]
    template = (target / "Environment.swift").read_text()
    assert template.count("// EXACT_PRODUCTION_VM_MEMBERS") == 1
    assert template.count("// EXACT_PRODUCTION_BLE_MEMBERS") == 1
    assert template.count("// EXACT_PRODUCTION_SUBMISSION_TYPE") == 1
    environment = template.replace("// EXACT_PRODUCTION_VM_MEMBERS", "\n".join(members))
    environment = environment.replace("// EXACT_PRODUCTION_BLE_MEMBERS", "\n".join(ble_members))
    environment = environment.replace("// EXACT_PRODUCTION_SUBMISSION_TYPE", submission)
    (destination / "Environment.swift").write_text(environment)
    names = ["manualAction", "pauseTask", "stop", "stopWithConversationControl", "cancelVoicePreparation", "releaseController", "release"]
    for name, text in zip(names, members + ble_members):
        (destination / (name + ".swift.txt")).write_text(text)
    # Fresh whole source copies are per-run evidence, never embedded test inputs.
    originals = ["PhoneAgent/PhoneAgentViewModel.swift", "PhoneAgent/Services/BLETransport.swift",
                 "Shared/InputReleaseController.swift", "Shared/AssistantConversationContext.swift"]
    for name in originals:
        snapshot = destination / "current-source" / name
        snapshot.parent.mkdir(parents=True, exist_ok=True)
        snapshot.write_bytes((root / name).read_bytes())
    (destination / "extraction.json").write_text(json.dumps({
        "schemaVersion": 1, "completeOriginalMethods": True, "methodSubstitutions": [],
        "methodSHA256": {name: hashlib.sha256(text.encode()).hexdigest() for name, text in zip(names, members + ble_members)},
        "wholeCurrentSourceSHA256": {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in originals},
        "limits": "Extracted-method/scaffold only; lower send/ACK, engine, queue/preparation/audio services are synthetic. Not complete VM/UI/voice/queue/ATT/HID integration.",
    }, indent=2) + "\n")
    print("Complete current production methods extracted without substitutions")


if __name__ == "__main__":
    main()
