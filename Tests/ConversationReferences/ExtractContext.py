#!/usr/bin/env python3
"""Extract the complete saved VM context builder without substitutions."""
from pathlib import Path
import hashlib
import json
import sys

root, template, output = [Path(value).resolve() for value in sys.argv[1:]]
output.mkdir(parents=True, exist_ok=False)
name = "PhoneAgent/Services/UnifiedConversationCoordinator.swift"
source = (root / name).read_bytes()
text = source.decode()
signature = "    func unifiedTaskContext(history messages: [AssistantMessage], question: String? = nil, originatingConversationID: UUID? = nil) -> String"
assert text.count(signature) == 1
start = text.index(signature); cursor = text.index("{", start) + 1; depth = 1
while depth:
    depth += (text[cursor] == "{") - (text[cursor] == "}")
    cursor += 1
method = text[start:cursor]
vm_source = (root / "PhoneAgent/PhoneAgentViewModel.swift").read_text()
pending_signature = "    func pendingTaskForConversation(_ conversationID: UUID) -> ConversationTaskSubmission?"
assert vm_source.count(pending_signature) == 1
pending_start = vm_source.index(pending_signature)
pending_cursor = vm_source.index("{", pending_start) + 1; pending_depth = 1
while pending_depth:
    pending_depth += (vm_source[pending_cursor] == "{") - (vm_source[pending_cursor] == "}")
    pending_cursor += 1
pending_method = vm_source[pending_start:pending_cursor]
environment = template.read_text()
assert environment.count("// EXACT_PRODUCTION_CONTEXT") == 1
(output / "ReferenceEnvironment.swift").write_text(environment.replace("// EXACT_PRODUCTION_CONTEXT", pending_method + "\n" + method))
(output / "context.swift.txt").write_text(method)
(output / "Coordinator.swift.original.txt").write_bytes(source)
shared = (root / "Shared/AssistantConversationContext.swift").read_bytes()
(output / "AssistantConversationContext.swift.original.txt").write_bytes(shared)
(output / "extraction.json").write_text(json.dumps({
    "methodSubstitutions": [], "completeMethod": True,
    "methodSHA256": hashlib.sha256(method.encode()).hexdigest(),
    "completePendingTaskHelperSHA256": hashlib.sha256(pending_method.encode()).hexdigest(),
    "wholeSourceSHA256": {name: hashlib.sha256(source).hexdigest(),
                          "PhoneAgent/PhoneAgentViewModel.swift": hashlib.sha256(vm_source.encode()).hexdigest(),
                          "Shared/AssistantConversationContext.swift": hashlib.sha256(shared).hexdigest()},
    "limits": "The complete VM context method and pending task helper are extracted; conversation identity, task record/history/engine containers are synthetic. Actual Ctrip parser/client decoder, store, input builder, router and both model request clients run with local fixtures; HTTP loaders replaced separately.",
}, indent=2) + "\n")
print("ConversationReferences: complete current context builder extracted without substitutions")
