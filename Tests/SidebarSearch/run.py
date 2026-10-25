#!/usr/bin/env python3
"""Check the exact sidebar enum and measure search without any live data."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source-root", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
root, output = args.source_root.resolve(), args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
source = (root / "PhoneAgent/Views/SidebarView.swift").read_text()
start = source.index("private enum SidebarHistoryEntry:")
end = source.index("\nstruct SidebarView:", start)
enum = source[start:end]
modern = "func matches(" in enum
adapter = "entry.matches(query)" if modern else "query.isEmpty || entry.searchableText.localizedCaseInsensitiveContains(query)"
models = '''import Foundation
import Darwin
struct PhoneTaskRecord {
    var id = UUID(); var title: String; var effectiveGoal: String; var updatedAt = Date()
}
struct SearchMessage { var text: String }
struct AssistantConversationRecord {
    var id = UUID(); var title: String; var draft: String; var messages: [SearchMessage]; var updatedAt = Date()
}
'''
body = r'''
var checks = 0
func expect(_ value: Bool, _ name: String) {
    precondition(value, name); checks += 1
}
@inline(never) func matches(_ entry: SidebarHistoryEntry, _ query: String) -> Bool { ADAPTER }
let conversation = AssistantConversationRecord(title: "Weekend plan 周末", draft: "unfinished 草稿",
    messages: [.init(text: "Flight AA 123"), .init(text: "需要核对 Café 和 🐱"), .init(text: "末尾 finish")])
let chat = SidebarHistoryEntry.conversation(conversation)
let fields = [conversation.title, conversation.draft] + conversation.messages.map(\.text)
for query in ["", "weekend", "PLAN", "周末", "草稿", "AA 123", "café", "🐱", "finish", "missing",
              "周末\nunfinished", "草稿\nFlight", "123\n需要", "🐱\n末尾", "\n", "missing\nfinish"] {
    let expected = query.isEmpty || fields.joined(separator: "\n").localizedCaseInsensitiveContains(query)
    expect(matches(chat, query) == expected, "Chat search parity: " + query)
}
let taskRecord = PhoneTaskRecord(title: "任务一", effectiveGoal: "First goal\n补充：保留原件")
let task = SidebarHistoryEntry.task(taskRecord)
for query in ["", "任务", "FIRST", "补充", "原件", "任务一\nFirst", "goal\n补充", "不存在"] {
    let expected = query.isEmpty || (taskRecord.title + "\n" + taskRecord.effectiveGoal).localizedCaseInsensitiveContains(query)
    expect(matches(task, query) == expected, "Task search parity: " + query)
}
expect(matches(.conversation(.init(title: "", draft: "", messages: [])), "x") == false, "Empty record")
let payload = String(repeating: "x", count: 58_000)
let large = SidebarHistoryEntry.conversation(.init(title: "Target title", draft: "Local draft",
    messages: (0..<80).map { .init(text: "Message \($0) " + payload + " end \($0)") }))
var titleTimes: [Double] = [], bodyTimes: [Double] = []
var hits = 0
for _ in 0..<3 {
    var start = ProcessInfo.processInfo.systemUptime
    for _ in 0..<200 { autoreleasepool { if matches(large, "TARGET TITLE") { hits += 1 } } }
    titleTimes.append(ProcessInfo.processInfo.systemUptime - start)
    start = ProcessInfo.processInfo.systemUptime
    for _ in 0..<10 { autoreleasepool { if matches(large, "end 79") { hits += 1 } } }
    bodyTimes.append(ProcessInfo.processInfo.systemUptime - start)
}
expect(hits == 630, "All benchmark queries return their expected hit")
var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
let result: [String: Any] = ["checks": checks, "messages": 80, "messageCharacters": 58_000,
    "titleHitQueriesPerRound": 200, "bodyHitQueriesPerRound": 10, "rounds": 3,
    "titleHitMedianSeconds": titleTimes.sorted()[1], "bodyHitMedianSeconds": bodyTimes.sorted()[1],
    "maxRSSMiB": Double(usage.ru_maxrss) / 1_048_576,
    "scope": "Synthetic 4.6MB conversation, extracted production enum; model structs are test fixtures, no UI/provider/phone claim"]
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
'''.replace("ADAPTER", adapter)
body = body.replace(chr(92) * 2, chr(92))
generated = models + enum.replace("private enum SidebarHistoryEntry:", "enum SidebarHistoryEntry:", 1) + "\n" + body
(output / "main.swift").write_text(generated)
subprocess.run(["xcrun", "swiftc", "-O", "-module-cache-path", str(output / "module-cache"), str(output / "main.swift"),
                "-o", str(output / "checks")], check=True)
report = json.loads(subprocess.check_output([str(output / "checks")], text=True))
report.update({"sourceRoot": str(root), "enumSHA256": hashlib.sha256(enum.encode()).hexdigest(),
               "extractionChanges": ["private visibility removed"], "streamingSearch": modern})
(output / "results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(report, ensure_ascii=False, indent=2))
