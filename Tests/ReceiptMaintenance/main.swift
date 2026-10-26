import Foundation

@main struct ReceiptMaintenanceChecks {
    @MainActor static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            if !condition() { fatalError(label) }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = Host()
        let current = UUID(), historical = UUID(), queued = UUID(), native = UUID(), ended = UUID(), unknown = UUID()
        host.engine.currentRecord = .init(id: current, outcome: .paused)
        host.history.records = [.init(id: historical, outcome: .stopped)]
        host.taskQueue.items = [.init(id: queued, resumable: true)]
        host.backgroundTasks.records = [.init(id: native, outcome: .needsUser)]
        let protected = host.toolReceiptMaintenanceContext
        for id in [current, historical, queued, native] {
            expect(protected.protectedTaskIDs.contains(id), "Every recoverable owner protects its receipts")
        }
        expect(!protected.executionInFlight, "Paused workers permit safe unrelated cleanup")
        let tools = SystemTools(url: folder.appendingPathComponent("receipts.json"))
        var fixtures: [String: SystemTools.Receipt] = [:]
        for id in [current, historical, queued, native, ended] {
            fixtures[id.uuidString + ":write"] = .init(id: UUID(), state: "completed", result: "真实原文\n🙂 \(id)")
        }
        fixtures[unknown.uuidString + ":write"] = .init(id: UUID(), state: "pending", result: nil)
        fixtures["unrecognized-legacy-key"] = .init(id: UUID(), state: "completed", result: "保留旧记录")
        try tools.seed(fixtures)
        let result = try tools.clearReceipts(context: protected)
        expect(result.removed == 1 && result.retained == 6, "Only ended task completion is removed")
        expect(tools.hasUnresolvedWrite(taskID: unknown), "Orphan unknown commit cannot be erased")
        for id in [current, historical, queued, native] {
            expect(tools.receipts[id.uuidString + ":write"]?.result == fixtures[id.uuidString + ":write"]?.result,
                   "Recoverable receipt payload remains exact")
        }
        let saved = try Data(contentsOf: tools.receiptURL)
        let persisted = try JSONDecoder().decode([String: SystemTools.Receipt].self, from: saved)
        expect(persisted.count == tools.receipts.count && persisted[unknown.uuidString + ":write"]?.state == "pending", "Unknown remains durable")
        let second = try tools.clearReceipts(context: protected)
        expect(second.removed == 0 && (try? Data(contentsOf: tools.receiptURL)) == saved, "Repeated maintenance does not rewrite or erase protected evidence")
        let actual = tools.completedTaskReceipts(taskID: current)
        expect(actual == [fixtures[current.uuidString + ":write"]!.result!], "Completed evidence belongs to exact task")
        expect(tools.completedTaskReceipts(taskID: unknown).isEmpty, "Pending is never completed evidence")

        func rejected(_ context: ToolReceiptMaintenanceContext, _ label: String) {
            do { _ = try tools.clearReceipts(context: context); expect(false, label) }
            catch { expect((try? Data(contentsOf: tools.receiptURL)) == saved && tools.receipts.count == 6, label) }
        }
        host.backgroundTasks.hasUnsettledExecution = true
        rejected(host.toolReceiptMaintenanceContext, "Native running or cancelled-in-flight blocks maintenance while main engine is idle")
        host.backgroundTasks.hasUnsettledExecution = false
        host.engine.executionSettled = false
        rejected(host.toolReceiptMaintenanceContext, "Main input release/settling blocks maintenance")
        host.engine.executionSettled = true
        host.queueRunning = true; rejected(host.toolReceiptMaintenanceContext, "Queue capable of dispatch blocks maintenance"); host.queueRunning = false
        host.queueSwitching = true; rejected(host.toolReceiptMaintenanceContext, "Queue switch blocks maintenance"); host.queueSwitching = false
        host.preparingAutomatically = true; rejected(host.toolReceiptMaintenanceContext, "Pending automatic start blocks maintenance"); host.preparingAutomatically = false
        host.history.error = "failed"; rejected(host.toolReceiptMaintenanceContext, "Unreadable history protects unknown task ownership"); host.history.error = ""
        host.taskQueue.error = "failed"; rejected(host.toolReceiptMaintenanceContext, "Unreadable queue protects unknown task ownership"); host.taskQueue.error = ""
        tools.pending = true; rejected(protected, "In-flight approval blocks cleanup independently"); tools.pending = nil
        tools.readable = false; rejected(protected, "Unreadable receipt file is preserved"); tools.readable = true
        expect(tools.completedTaskReceipts(taskID: current).count == 1, "Readable completed evidence restored without replay")

        // Exercise the unchanged service transaction with a failed replacement.
        try tools.seed(fixtures)
        let before = try Data(contentsOf: tools.receiptURL)
        let originalURL = tools.receiptURL
        let blocker = folder.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blocker)
        tools.receiptURL = blocker.appendingPathComponent("receipts.json")
        do { _ = try tools.clearReceipts(context: protected); expect(false, "Expected save failure") }
        catch { expect(tools.receipts.count == fixtures.count && (try? Data(contentsOf: originalURL)) == before, "Failed cleanup preserves both published receipts and prior file") }
        tools.receiptURL = originalURL
        let cleaned = try tools.clearReceipts(context: protected)
        expect(cleaned.removed == 1 && tools.hasUnresolvedWrite(taskID: unknown), "Explicit retry remains safe")
        expect(!ToolReceiptMaintenancePolicy.mayRemove(key: current.uuidString + ":write", state: "pending", context: .init(protectedTaskIDs: [], executionInFlight: false, taskStorageAvailable: true)), "Unknown remains protected even without task history")
        print("Receipt maintenance: \(checks) production host/policy/service checks passed; temporary records only, no OS writes or accounts")
    }
}
