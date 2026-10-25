import Foundation

let first = UUID(), second = UUID()
var count = 0
func expect(_ value: @autoclosure () -> Bool, _ label: String) {
    guard value() else { fatalError(label) }
    count += 1
}
let a = TaskActivityLink.url(taskID: first), b = TaskActivityLink.url(taskID: second)
expect(a != b, "Two task receipts need distinct links")
expect(TaskActivityLink.taskID(from: a) == first, "Opening an archived receipt selects its own task")
expect(TaskActivityLink.taskID(from: b) == second, "A later task retains its separate identity")
for raw in ["phoneagent://task", "phoneagent://task?id=bad", "phoneagent://task?id=",
            "phoneagent://task?id=\(first)&id=\(second)", "phoneagent://task?id=\(first)&run=true",
            "phoneagent://task/path?id=\(first)", "phoneagent://task?id=\(first)#run",
            "phoneagent://other?id=\(first)", "https://task?id=\(first)",
            "phoneagent://user@task?id=\(first)", "phoneagent://task:80?id=\(first)"] {
    expect(TaskActivityLink.taskID(from: URL(string: raw)!) == nil, "Reject ambiguous or unrelated route: \(raw)")
}
print("PASS: \(count) task activity link identity and invalid-link checks")
for (phase, label) in [("preparing", "Prepare"), ("acting", "Working"), ("observing", "Thinking"),
                       ("awaitingApproval", "Confirm"), ("needsUser", "Your turn"), ("paused", "Paused"),
                       ("completed", "Done"), ("failed", "Error"), ("stopped", "Stopped"),
                       ("idle", "Ready"), ("preview", "Ready")] {
    expect(TaskActivityPresentation.label(phase: phase, isStale: false) == label, "Correct current phase")
    expect(TaskActivityPresentation.label(phase: phase, isStale: true) == "待核对", "Stale compact UI must not claim running or done")
    expect(TaskActivityPresentation.portraitPhase(phase: phase, isStale: true) == "needsUser", "Stale minimal UI needs a check state")
}
print("PASS: \(count) total activity route and phase presentation checks")
