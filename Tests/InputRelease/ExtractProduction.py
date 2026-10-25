#!/usr/bin/env python3
"""Compile original method bytes against synthetic transport I/O, never CoreBluetooth init."""
from pathlib import Path
import hashlib
import json
import sys

root = Path(__file__).resolve().parents[2]
output = Path(sys.argv[1])
ble = (root / "PhoneAgent/Services/BLETransport.swift").read_text()
vm = (root / "PhoneAgent/PhoneAgentViewModel.swift").read_text()


def member(text, signature):
    assert text.count(signature) == 1, signature
    start = text.index(signature)
    opening = text.index("{", start)
    depth = 1
    cursor = opening + 1
    while depth:
        depth += (text[cursor] == "{") - (text[cursor] == "}")
        cursor += 1
    return text[start:cursor]


start = ble.index("    private lazy var releaseController =")
end = ble.index("    var ready:", start)
methods = ble[start:end] + "\n" + "\n".join(member(ble, signature) for signature in [
    "    func beginPointerMotion()", "    func endPointerMotion(",
    "    @discardableResult\n    func send(_ op:", "    private func writeCommand(",
    "    func moveBuffered(", "    @discardableResult func release(",
    "    func waitIdle(", "    private func clear()",
    "    func peripheral(_ p: CBPeripheral, didWriteValueFor",
])
manual = member(vm, "    func manualAction(allowsBackgroundScreen:")
template = (root / "Tests/InputRelease/Environment.swift").read_text()
assert template.count("// PRODUCTION_BLE_MEMBERS") == template.count("// PRODUCTION_MANUAL_ACTION") == 1
generated = template.replace("// PRODUCTION_BLE_MEMBERS", methods).replace("// PRODUCTION_MANUAL_ACTION", manual)
(output / "Environment.swift").write_text(generated)
files = ["Shared/InputReleaseController.swift", "Shared/AgentModels.swift", "Shared/MouseProtocol.swift",
         "PhoneAgent/Services/HIDKeyboard.swift", "PhoneAgent/Services/MouseExecutor.swift",
         "PhoneAgent/Services/BLETransport.swift", "PhoneAgent/PhoneAgentViewModel.swift"]
(output / "input-hashes.json").write_text(json.dumps({
    "files": {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in files},
    "extractedBLEMembersSHA256": hashlib.sha256(methods.encode()).hexdigest(),
    "extractedManualActionSHA256": hashlib.sha256(manual.encode()).hexdigest(),
    "unchangedMethodBytes": True,
    "syntheticTransportOnly": True,
}, indent=2) + "\n")
