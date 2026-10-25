import Foundation

@main struct SnapshotChecks {
    @MainActor static func main() throws {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            count += 1; guard condition else { fatalError(message) }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("native-snapshot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("conversations.json")
        let conversationID = UUID(), taskID = UUID(), messageID = UUID(), now = Date()
        let alarmID = UUID().uuidString
        let card = NativeTaskResult.completed(operation: "alarm_create",
            result: "已添加 Sela 闹钟：早起 · 2026-10-26T09:10:00+08:00 · 回执 " + alarmID,
            title: "不使用计划标题", start: nil, eventID: "unused")!
        var task = PhoneTaskRecord(id: taskID, title: "真实完成记录", goal: "HOST_ONLY_GOAL_DO_NOT_ARCHIVE", updatedAt: now,
            outcome: .completed, summary: "真实完成报告", nativeResults: [card])
        let snapshot = task.nativeConversationSnapshot!
        check(snapshot.results == [card] && snapshot.taskID == taskID && snapshot.state == .completed,
              "Snapshot is produced from actual retained task fields and native result")
        task.outcome = .running
        check(task.nativeConversationSnapshot == nil, "A running checkpoint is not archived as a settled result")
        task.outcome = .completed
        let archive = AssistantConversationStore(url: path)
        let record = AssistantConversationRecord(id: conversationID, title: "测试对话", messages: [
            AssistantMessage(role: "user", text: "设闹钟"),
            AssistantMessage(id: messageID, role: "assistant", text: "任务已启动", taskID: taskID)
        ], createdAt: now, updatedAt: now, recipient: "offline", draft: "尚未发送的草稿")
        try archive.save([record], currentConversationID: conversationID)
        let conversation = AssistantConversation(store: archive)
        let beforeFocus = conversation.focusedTaskID
        check(conversation.retainTaskResult(snapshot), "Existing linked assistant message receives actual result")
        check(conversation.messages.last?.nativeTaskResult == snapshot, "Published card matches saved evidence")
        check(conversation.draft == record.draft && conversation.focusedTaskID == beforeFocus,
              "Archiving a result preserves draft and selection")
        check(conversation.conversations.first?.updatedAt == now && conversation.currentConversationID == conversationID,
              "Archiving evidence does not reorder chats or switch the active conversation")
        let firstBytes = try Data(contentsOf: path)
        check(conversation.retainTaskResult(snapshot), "Repeated receipt snapshot is accepted idempotently")
        check(try Data(contentsOf: path) == firstBytes, "Unchanged snapshots never rewrite the archive")
        let serialized = String(decoding: firstBytes, as: UTF8.self)
        check(!serialized.contains("HOST_ONLY_GOAL_DO_NOT_ARCHIVE") && !serialized.contains("checkpointStep")
              && !serialized.contains("attemptStartStep") && !serialized.contains("logs"),
              "Snapshot cannot restore execution goals, checkpoints, logs or authority")
        let history = TaskHistoryStore(url: folder.appendingPathComponent("tasks.json"))
        history.upsert(task)
        for i in 0..<51 {
            history.upsert(PhoneTaskRecord(title: "后续记录\(i)", goal: "离线保留上限夹具", outcome: .completed))
        }
        check(history.records.count == 50 && !history.records.contains(where: { $0.id == taskID }),
              "Actual production task store evicts the original record at its real limit")
        let cold = AssistantConversation(store: AssistantConversationStore(url: path))
        check(cold.messages.last?.nativeTaskResult == snapshot && cold.messages.last?.nativeTaskResult?.results.first?.id == alarmID,
              "Actual conversation archive and cold reload retain the original card after task eviction")
        check(cold.messages.last?.nativeTaskResult?.results.first?.date == card.date,
              "Original actual alarm instant survives history eviction and restart")
        let otherTask = UUID()
        let unlinked = NativeTaskSnapshot(taskID: otherTask, title: "未关联", summary: "不应插入", outcome: "completed", updatedAt: now, results: [card])!
        check(!cold.retainTaskResult(unlinked) && cold.messages.count == 2,
              "Late unrelated receipt cannot create a task message or another conversation")
        let old = NativeTaskSnapshot(taskID: taskID, title: "旧状态", summary: "旧摘要", outcome: "paused",
            updatedAt: now.addingTimeInterval(-1), results: [card])!
        check(cold.retainTaskResult(old) && cold.messages.last?.nativeTaskResult == snapshot,
              "A stale completion cannot overwrite newer stored evidence")
        cold.newConversation(); cold.draft = "新对话中的草稿"
        let newConversationID = cold.currentConversationID
        let changed = NativeTaskSnapshot(taskID: taskID, title: "真实完成记录", summary: "后续核对结果", outcome: "completed",
            updatedAt: now.addingTimeInterval(1), results: [card])!
        check(cold.retainTaskResult(changed), "Result can be retained in its background conversation")
        check(cold.currentConversationID == newConversationID && cold.draft == "新对话中的草稿" && cold.messages.isEmpty,
              "Background result cannot steal focus, change drafts or insert into the foreground conversation")
        let background = cold.conversations.first { $0.id == conversationID }!
        check(background.messages.last?.nativeTaskResult == changed, "Background card updates only the correct conversation")
        var invalid = record
        invalid.messages[1].nativeTaskResult = unlinked
        let saved = try Data(contentsOf: path)
        var rejected = false
        do { try archive.save([invalid], currentConversationID: conversationID) } catch { rejected = true }
        check(try rejected && Data(contentsOf: path) == saved, "Cross-task archive identity mismatch is rejected transactionally")
        invalid.messages[1].nativeTaskResult = snapshot; invalid.messages[1].role = "user"; rejected = false
        do { try archive.save([invalid], currentConversationID: conversationID) } catch { rejected = true }
        check(try rejected && Data(contentsOf: path) == saved, "A user message cannot carry host success evidence")
        let brokenPath = folder.appendingPathComponent("broken.json"), broken = Data("{invalid".utf8)
        try broken.write(to: brokenPath)
        let brokenConversation = AssistantConversation(store: AssistantConversationStore(url: brokenPath))
        check(try !brokenConversation.retainTaskResult(snapshot) && Data(contentsOf: brokenPath) == broken,
              "Corrupt archive is retained and never replaced with fabricated snapshot history")
        print("Native task snapshots: \(count) actual model/store/service checks passed; 51 synthetic records, no phone/model/network")
    }
}
