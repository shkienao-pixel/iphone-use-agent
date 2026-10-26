import Foundation
import Combine

@main struct TaskHistoryPersistenceChecks {
    struct LegacyDocument: Codable { var version = 1; var records: [PhoneTaskRecord] }
    @MainActor static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); count += 1
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-transaction-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let working = folder.appendingPathComponent("working")
        let path = working.appendingPathComponent("tasks.json")
        let store = TaskHistoryStore(url: path)
        var task = PhoneTaskRecord(title: "原生暂停任务", goal: "保持原始目标", outcome: .paused,
            amendments: [TaskAmendment(text: "明确补充")], conversationReference: "真实会话引用", executionLane: "native",
            checkpointStep: 17, attemptStartStep: 3)
        task.logs = [.init(step: 17, title: "工具回执", detail: "已核对前17步")]
        check(store.upsert(task), "Successful upsert acknowledges a durable checkpoint")
        let saved = try Data(contentsOf: path)
        let document = try JSONDecoder().decode(LegacyDocument.self, from: saved)
        check(document.version == 1 && document.records.first?.id == task.id, "Existing version-one schema and task identity remain unchanged")
        var publications = 0
        let observation = store.$records.dropFirst().sink { records in
            publications += 1
            let disk = try? JSONDecoder().decode(LegacyDocument.self, from: Data(contentsOf: path))
            precondition(disk?.records.map(\.id) == records.map(\.id), "Every published repository snapshot must already be on disk")
            precondition(disk?.records.first?.summary == records.first?.summary, "Published task content must match its committed file")
        }

        // A blocked parent makes writes fail even when tests run as a user who
        // can bypass read-only permission bits. Preserve the original file aside.
        let backup = folder.appendingPathComponent("original-storage")
        try FileManager.default.moveItem(at: working, to: backup)
        try Data("not a directory".utf8).write(to: working)
        var updated = task; updated.outcome = .completed; updated.summary = "不得提前发布的完成状态"
        check(!store.upsert(updated), "A failed checkpoint write reports false to the host")
        check(store.records.first?.outcome == .paused && store.records.first?.summary == task.summary,
            "Failed writes cannot publish new completion or replace the last durable checkpoint")
        check(publications == 0 && !store.error.isEmpty, "Failed writes publish no record changes and expose a blocking storage error")
        check((try? Data(contentsOf: backup.appendingPathComponent("tasks.json"))) == saved,
            "The original durable archive is unchanged after a write failure")
        check(!store.rename(task.id, title: "不得发布的新标题") && store.records.first?.title == task.title,
            "Rename follows the same commit-before-publish contract")
        check(!store.remove(task.id) && store.records.first?.id == task.id,
            "Deletion cannot disappear from memory when its durable commit fails")
        try FileManager.default.removeItem(at: working)
        try FileManager.default.moveItem(at: backup, to: working)
        check(store.upsert(updated) && store.error.isEmpty && publications == 1,
            "An explicit retry after storage recovery commits once and clears the error")
        observation.cancel()
        check(TaskHistoryStore(url: path).records.first?.outcome == .completed,
            "Restart reads exactly the successfully committed completion")

        let batchFolder = folder.appendingPathComponent("batch-working")
        let batchPath = batchFolder.appendingPathComponent("tasks.json")
        let batchStore = TaskHistoryStore(url: batchPath)
        var first = task; first.id = UUID(); first.summary = "first saved"
        var second = task; second.id = UUID(); second.summary = "second saved"
        check(batchStore.saveCheckpoints([first, second]), "A batch saves all selected engine checkpoints in one acknowledged transaction")
        let initialBatchBytes = try Data(contentsOf: batchPath)
        var batchPublications = 0
        let batchObservation = batchStore.$records.dropFirst().sink { records in
            batchPublications += 1
            let disk = try? JSONDecoder().decode(LegacyDocument.self, from: Data(contentsOf: batchPath))
            precondition(disk?.records.map(\.id) == records.map(\.id), "A batch is entirely durable before its one publication")
            precondition(disk?.records.map(\.summary) == records.map(\.summary), "No batch observer sees partial checkpoint contents")
        }
        var firstUpdate = first; firstUpdate.summary = "first retry"; firstUpdate.checkpointStep = 23
        var secondUpdate = second; secondUpdate.summary = "second retry"; secondUpdate.checkpointStep = 29
        var badBatchElement = secondUpdate; badBatchElement.conversationReference = String(repeating: "x", count: 64_001)
        check(!batchStore.saveCheckpoints([firstUpdate, badBatchElement]), "An invalid later batch element rejects the entire batch")
        check(batchStore.records.map(\.summary) == [first.summary, second.summary] && batchPublications == 0,
            "A valid earlier batch element cannot partially update the repository")
        check((try? Data(contentsOf: batchPath)) == initialBatchBytes, "Invalid batches preserve the complete original file")
        check(!batchStore.saveCheckpoints([firstUpdate, firstUpdate]) && batchPublications == 0,
            "Ambiguous duplicate task IDs cannot silently select one checkpoint version")
        let batchBackup = folder.appendingPathComponent("batch-backup")
        try FileManager.default.moveItem(at: batchFolder, to: batchBackup)
        try Data("not a directory".utf8).write(to: batchFolder)
        let third = PhoneTaskRecord(title: "新检查点", goal: "本批新增", outcome: .paused, executionLane: "native")
        check(!batchStore.saveCheckpoints([firstUpdate, secondUpdate, third]), "A batch write failure reports a failed commit")
        check(batchStore.records.map(\.id) == [first.id, second.id] && batchStore.records.map(\.summary) == [first.summary, second.summary],
            "A failed batch neither replaces old tasks nor publishes its new task")
        check(batchPublications == 0 && !batchStore.error.isEmpty, "Failed batch commits produce no provisional publication")
        check(!batchStore.saveCheckpoints([]) && batchPublications == 0,
            "Empty retry is a real storage commit and cannot clear an ongoing write failure")
        check((try? Data(contentsOf: batchBackup.appendingPathComponent("tasks.json"))) == initialBatchBytes,
            "Failed batch and empty retries preserve the original durable archive")
        try FileManager.default.removeItem(at: batchFolder)
        try FileManager.default.moveItem(at: batchBackup, to: batchFolder)
        check(batchStore.saveCheckpoints([firstUpdate, secondUpdate, third]) && batchPublications == 1 && batchStore.error.isEmpty,
            "Explicit batch retry durably saves all current engine checkpoints with one publication")
        let batchCold = TaskHistoryStore(url: batchPath)
        check(batchCold.records.map(\.id) == [first.id, second.id, third.id] && batchCold.records.first?.checkpointStep == 23 && batchCold.records[1].checkpointStep == 29,
            "Restart sees every successful batch update with exact execution checkpoints")
        let semanticBeforeEmpty = try JSONSerialization.jsonObject(with: Data(contentsOf: batchPath)) as! NSDictionary
        check(batchStore.saveCheckpoints([]) && batchStore.error.isEmpty && batchPublications == 2,
            "Empty explicit retry saves a readable snapshot without starting or restoring an engine")
        let semanticAfterEmpty = try JSONSerialization.jsonObject(with: Data(contentsOf: batchPath)) as! NSDictionary
        check(semanticBeforeEmpty.isEqual(semanticAfterEmpty),
            "Empty retry preserves every record value and version-one schema")
        batchObservation.cancel()

        var invalid = task; invalid.id = UUID(); invalid.conversationReference = String(repeating: "x", count: 64_001)
        let beforeInvalid = try Data(contentsOf: path)
        check(!store.upsert(invalid) && !store.records.contains { $0.id == invalid.id },
            "Invalid input produces no provisional in-memory task")
        check((try? Data(contentsOf: path)) == beforeInvalid, "Invalid input preserves the complete existing archive")
        var oversized = task; oversized.id = UUID(); oversized.summary = String(repeating: "x", count: 64_000_001)
        check(!store.upsert(oversized) && !store.records.contains { $0.id == oversized.id },
            "Capacity failure rejects the new checkpoint without evicting or publishing existing records")
        check((try? Data(contentsOf: path)) == beforeInvalid, "Capacity failure does not replace the previous file")

        let retainedPath = folder.appendingPathComponent("retention.json")
        let retention = TaskHistoryStore(url: retainedPath)
        let recoverable: [TaskOutcome] = [.running, .paused, .needsUser, .failed, .stopped, .interrupted]
        var pinned: [PhoneTaskRecord] = []
        for (index, outcome) in recoverable.enumerated() {
            var record = task; record.id = UUID(); record.outcome = outcome
            record.title = "检查点 \(index)"; record.checkpointStep = 40 + index
            pinned.append(record)
            check(retention.upsert(record), "Every existing recoverable outcome can be durably retained")
        }
        for index in 0..<70 {
            let record = PhoneTaskRecord(title: "已结束 \(index)", goal: "离线完成记录", outcome: index.isMultiple(of: 2) ? .completed : .preview)
            check(retention.upsert(record), "Completed history commits without deleting working checkpoints")
        }
        check(retention.records.count == pinned.count + 50, "Only completed/preview display history is bounded at fifty")
        check(Set(pinned.map(\.id)).isSubset(of: Set(retention.records.map(\.id))),
            "All unfinished, failed and stopped task checkpoints survive unrelated history churn")
        let cold = TaskHistoryStore(url: retainedPath)
        check(cold.records.count == pinned.count + 50 && cold.error.isEmpty, "Mixed checkpoint/display retention survives restart")
        for original in pinned {
            let restored = cold.records.first { $0.id == original.id }
            check(restored?.goal == original.goal && restored?.effectiveGoal == original.effectiveGoal && restored?.checkpointStep == original.checkpointStep && restored?.attemptStartStep == original.attemptStartStep,
                "Restart preserves the exact task instructions, supplements and execution budget")
            let expected = [.running, .paused, .needsUser].contains(original.outcome) ? TaskOutcome.interrupted : original.outcome
            check(restored?.outcome == expected && restored?.completionEvidence == nil,
                "Loading retains current recovery semantics without inventing completion evidence or execution authority")
        }

        // Simulate an existing version-one file with a checkpoint after the
        // fiftieth row. Loading must not apply the old blind prefix(50) rule.
        let legacyPath = folder.appendingPathComponent("legacy-v1.json")
        let finished = (0..<60).map { PhoneTaskRecord(title: "旧完成 \($0)", goal: "已有历史", outcome: .completed) }
        let legacy = try JSONEncoder().encode(LegacyDocument(records: finished + pinned))
        try legacy.write(to: legacyPath)
        let legacyStore = TaskHistoryStore(url: legacyPath)
        check(legacyStore.error.isEmpty && legacyStore.records.count == 50 + pinned.count,
            "Version-one archives retain checkpoints beyond the former fifty-row prefix")
        check(Set(pinned.map(\.id)).isSubset(of: Set(legacyStore.records.map(\.id))),
            "Legacy loading does not discard old paused, failed or stopped native records")
        check((try? Data(contentsOf: legacyPath)) == legacy, "Read-time recovery does not rewrite or migrate the original archive silently")
        check(legacyStore.remove(pinned[0].id) && !TaskHistoryStore(url: legacyPath).records.contains { $0.id == pinned[0].id },
            "Explicit user deletion can still remove an individually selected checkpoint")

        let brokenPath = folder.appendingPathComponent("corrupt.json"), broken = Data("{broken".utf8)
        try broken.write(to: brokenPath)
        let brokenStore = TaskHistoryStore(url: brokenPath)
        check(!brokenStore.upsert(task) && brokenStore.records.isEmpty && !brokenStore.error.isEmpty,
            "An unreadable repository explicitly refuses new task commits")
        check(!brokenStore.saveCheckpoints([]) && !brokenStore.saveCheckpoints([task]),
            "Neither empty nor populated retries replace an unreadable original archive")
        check((try? Data(contentsOf: brokenPath)) == broken, "Corrupt archives are preserved without replacement")
        let futurePath = folder.appendingPathComponent("future.json")
        let future = try JSONEncoder().encode(LegacyDocument(version: 2, records: [task]))
        try future.write(to: futurePath)
        check(!TaskHistoryStore(url: futurePath).upsert(task) && (try? Data(contentsOf: futurePath)) == future,
            "A future schema is preserved and rejected without downgrade")
        check(!TaskHistoryStore(url: futurePath).saveCheckpoints([]) && (try? Data(contentsOf: futurePath)) == future,
            "Empty retry cannot downgrade a future-version archive")
        print("Task history persistence: \(count) real repository checks passed; no phone, network or model calls")
    }
}
