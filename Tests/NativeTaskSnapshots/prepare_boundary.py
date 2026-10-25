"""Use existing model/image doubles; compile both real stores and their models."""
from pathlib import Path
import sys

root, output = map(Path, sys.argv[1:])
source = (root / "Tests/AssistantConversation/Environment.swift").read_text()
for signature in ("enum TaskOutcome", "struct PhoneTaskRecord"):
    a = source.index(signature)
    b = source.index("{", a) + 1
    depth = 1
    while depth:
        depth += (source[b] == "{") - (source[b] == "}")
        b += 1
    source = source[:a] + source[b:]
source = source.replace("struct AgentLogEntry {", "struct AgentLogEntry: Codable { var step = 0;")
source += "\nstruct TaskContextMemory: Codable { var compactedEntryCount = 0; var retainedEntryCount = 0; var truncatedCharacterCount = 0 }\n"
output.write_text(source)
