import Foundation

/// Whole production composer, send, navigation, pause and route bridge. Only
/// SwiftUI binding, model reply and hardware/audio services are local doubles.
@main struct ComposerControlChecks {
    @MainActor static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var rows: [[String: Any]] = [], checks = 0
        func expect(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }
        func wait(_ predicate: () -> Bool) async throws {
            for _ in 0..<4000 { if predicate() { return }; try await Task.sleep(for: .milliseconds(1)) }
            throw AgentError.message("Offline composer check timed out")
        }
        for mode in [ConversationRoute.Mode.supplement, .stop] {
            for taskPage in [true, false] {
                for laterChange in ["none", "pause", "engineReplacement"] {
                    let model = NavigationModel(AssistantConversation(store: AssistantConversationStore(url: folder.appendingPathComponent(UUID().uuidString + ".json"))))
                    let nav = NavigationHarness(model)
                    let record = PhoneTaskRecord(title: "离线任务", goal: "打开计算器", summary: "running")
                    model.engine.currentRecord = record; model.engine.running = true; model.history.records = [record]
                    nav.screen = .conversation(record.id); nav.selectedDestination = taskPage ? .tasks : .assistant
                    model.installBridge(); OfflineRoute.mode = mode; OfflineRoute.captured = nil; OfflineRoute.gate = nil; OfflineRoute.hold = true
                    var actionCalls = 0
                    model.conversation.onAction = { _, _ in actionCalls += 1 }
                    let before = model.conversationControlContext
                    expect(nav.canInputForChecks, "Running task allows composer input")
                    nav.sendForChecks(mode == .stop ? "停止当前任务" : "补充：只查看不要修改")
                    let afterSubmit = model.conversationControlContext
                    try await wait { OfflineRoute.gate != nil }
                    expect(OfflineRoute.captured?.controlContext == afterSubmit, "Send captures the completed navigation transition")
                    expect((before.queueID != afterSubmit.queueID) == taskPage && model.engine.paused == taskPage,
                           "Task page retains its navigation pause; existing chat does not pause")
                    if laterChange == "pause" { _ = model.pauseTask() }
                    if laterChange == "engineReplacement" {
                        model.engine.activityControlSessionID = UUID()
                        model.engine.currentRecord = PhoneTaskRecord(title: "另一任务", goal: "other", summary: "running")
                    }
                    let gate = OfflineRoute.gate; OfflineRoute.gate = nil; gate?.resume()
                    try await wait { !model.conversation.loading }
                    if laterChange == "none" {
                        expect(actionCalls == 1 && model.conversation.error.isEmpty, "Valid supplement/stop survives its own page transition")
                    } else {
                        expect(actionCalls == 0 && model.conversation.error.contains("任务状态已改变"), "Later pause or task replacement still revokes control")
                    }
                    rows.append(["mode": mode.rawValue, "taskPage": taskPage, "laterChange": laterChange,
                                 "actionCalls": actionCalls, "error": model.conversation.error])
                }
            }
        }
        let rejectedModel = NavigationModel(AssistantConversation(store: AssistantConversationStore(url: folder.appendingPathComponent("rejected.json"))))
        let rejectedNav = NavigationHarness(rejectedModel); rejectedModel.engine.running = true
        let beforeRejected = rejectedModel.conversationControlContext
        rejectedNav.sendForChecks(String(repeating: "长", count: 4001))
        expect(rejectedModel.conversationControlContext == beforeRejected && rejectedModel.engine.running && rejectedNav.selectedDestination == .tasks,
               "Rejected input does not navigate, pause or consume control state")
        let bytes = try JSONSerialization.data(withJSONObject: ["checks": checks, "cases": rows, "offlineOnly": true], options: [.prettyPrinted, .sortedKeys])
        try bytes.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
        print("PASS: \(checks) actual composer/navigation/control checks; no model or device")
    }
}
