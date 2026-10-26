import Foundation

@main struct RecoveryControllerChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) { precondition(value(), label); checks += 1 }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TaskRecovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory); PrivacyConsent.revoke() }
        func make(_ name: String) throws -> PhoneAgentViewModel {
            let folder = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return PhoneAgentViewModel(directory: folder)
        }
        func settled(_ vm: PhoneAgentViewModel) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !vm.engine.executionSettled {
                precondition(Date() < deadline, "Controller recovery fixture timed out")
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        ModelProbe.calls = 0; ModelProbe.delay = 0; ModelProbe.onRequest = nil; ModelProbe.actionProvider = nil
        ModelProbe.action = AgentAction(kind: .ask_user, reason: "Observe current state")
        let vm = try make("ordinary")
        PrivacyConsent.grant(vm.settings)
        let source = PhoneTaskRecord(title: "Selected failed task", goal: "Only this task", outcome: .failed,
            logs: [.init(step: 4, title: "工具回执", detail: "Confirmed source receipt")], checkpointStep: 4)
        vm.history.upsert(source)
        let otherChat = RecoveryChatMessage(taskID: UUID())
        vm.conversation.messages = [otherChat]; vm.unifiedFocusedTaskID = otherChat.taskID
        expect(vm.recoverableTask(source.id)?.id == source.id && vm.engine.currentRecord == nil && ModelProbe.calls == 0,
               "Discovering a recoverable history entry does not start it")
        expect(!vm.continueTask(UUID()) && ModelProbe.calls == 0, "Unknown task IDs cannot recover another task")
        vm.preparationReady = false
        expect(!vm.continueTask(source.id) && vm.showPreparation && ModelProbe.calls == 0, "Unready recovery opens preparation without starting or scheduling a task")
        vm.preparationReady = true
        try await Task.sleep(nanoseconds: 20_000_000)
        expect(ModelProbe.calls == 0 && vm.engine.currentRecord == nil, "Finishing preparation alone does not revive a pending recovery request")
        let busyMutations: [(PhoneAgentViewModel) -> Void] = [
            { $0.recordingAudioOwner = UUID() }, { $0.preparingAutomatically = true }, { $0.queueRunning = true },
            { $0.queueSwitching = true }, { $0.voicePending = true }, { $0.voiceMode = "active" },
            { $0.manualBusy = true }, { $0.calibrating = true }, { $0.executor.calibrationInProgress = true },
            { $0.pendingConsentStart = true }, { $0.pendingConversationTask = UUID() }, { $0.speech.usingAudio = true }, { $0.tools.pending = true },
            { $0.conversation.loading = true }
        ]
        for (index, mutate) in busyMutations.enumerated() {
            let busy = try make("busy-\(index)"); busy.history.upsert(source); mutate(busy)
            expect(!busy.retryTask(source.id) && busy.engine.currentRecord == nil && ModelProbe.calls == 0,
                   "Resource lock \(index) cannot be replaced by selecting a failed task")
        }
        UIApplication.shared.applicationState = .inactive
        expect(!vm.retryTask(source.id) && ModelProbe.calls == 0, "Historical task recovery requires an explicit foreground interaction")
        UIApplication.shared.applicationState = .active
        vm.manualContinuationRequired = true
        expect(!vm.continueTask(source.id) && ModelProbe.calls == 0, "Unreviewed manual input cannot be bypassed by retrying a historical task")
        vm.manualContinuationRequired = false
        expect(vm.continueTask(source.id), "An explicit continue starts only the selected historical task")
        expect(!vm.retryTask(source.id), "A second recovery click cannot launch an overlapping attempt")
        try await settled(vm)
        expect(vm.engine.currentRecord?.id == source.id && vm.engine.currentStep == 5 && ModelProbe.calls == 1,
               "Controller restores the selected identity and exact old step budget")
        expect(vm.conversation.messages == [otherChat] && vm.unifiedFocusedTaskID == otherChat.taskID,
               "Recovering an archived task does not attach it to or refocus an unrelated conversation")
        var foreign = source; foreign.id = UUID(); vm.history.upsert(foreign)
        expect(!vm.retryTask(foreign.id) && vm.engine.currentRecord?.id == source.id && ModelProbe.calls == 1,
               "Another paused task session is not stopped or replaced by an unrelated recovery click")
        vm.conversation.messages.append(RecoveryChatMessage(taskID: source.id))
        let originalMessages = vm.conversation.messages, firstAttempt = vm.engine.runMetrics!.snapshot.id
        expect(vm.retryTask(source.id), "The selected paused task supports a fresh retry attempt")
        try await settled(vm)
        expect(vm.engine.runMetrics!.snapshot.id != firstAttempt && vm.engine.currentRecord?.attemptStartStep == 5,
               "Retry takes a new attempt budget without changing the task scope")
        expect(vm.conversation.messages == originalMessages && vm.unifiedFocusedTaskID == source.id,
               "Only an already-linked current conversation may focus its own recovered task")
        vm.engine.stop(); try await settled(vm)
        expect(vm.recoverableTask(source.id)?.outcome == .stopped && vm.continueTask(source.id),
               "A stopped task remains explicitly recoverable despite revoked old resume authority")
        try await settled(vm)
        expect(vm.engine.currentRecord?.id == source.id, "Stop followed by continue retains the original identity")
        vm.engine.stop(); try await settled(vm)

        let queued = try make("queued"); queued.history.upsert(source)
        try queued.taskQueue.append(.init(record: source, settings: queued.settings, step: 4, started: true, state: .suspended))
        try queued.taskQueue.append(.init(record: foreign, settings: queued.settings, state: .waiting))
        expect(queued.continueTask(source.id) && !queued.queueRunning && queued.activeQueueForChecks == source.id,
               "Recovering one queued history task never authorizes the entire waiting queue")
        try await settled(queued)
        expect(queued.engine.currentRecord?.id == source.id && queued.taskQueue.items[1].state == .waiting,
               "Unselected queued tasks and their state remain untouched")
        queued.engine.stop(); try await settled(queued)
        let coherent = try make("coherent-checkpoint")
        coherent.history.upsert(source)
        var newerQueue = source
        newerQueue.updatedAt = source.updatedAt.addingTimeInterval(30)
        newerQueue.logs.append(.init(step: 9, title: "工具回执", detail: "Newer complete queue receipt"))
        newerQueue.subtasks = [.init(goal: "Already confirmed in queue", completed: true, evidence: "Queue receipt")]
        newerQueue.checkpointStep = 9; newerQueue.attemptStartStep = 7
        try coherent.taskQueue.append(.init(record: newerQueue, settings: coherent.settings, step: 9, started: true, state: .suspended))
        let checkpoint = coherent.recoverableTask(source.id)!
        expect(checkpoint.checkpointStep == 9 && checkpoint.attemptStartStep == 7 && checkpoint.logs.last?.detail == "Newer complete queue receipt",
               "A newer queued checkpoint contributes its complete record, not just a higher step counter")
        expect(checkpoint.subtasks?.first?.completed == true && checkpoint.subtasks?.first?.evidence == "Queue receipt",
               "A stale history file cannot erase confirmed subtasks from the newer queue snapshot")
        var newestHistory = newerQueue
        newestHistory.checkpointStep = 10
        newestHistory.logs.append(.init(step: 10, title: "工具回执", detail: "Newest history receipt"))
        coherent.history.upsert(newestHistory)
        expect(coherent.recoverableTask(source.id)?.logs.last?.detail == "Newest history receipt",
               "A newer complete history checkpoint is not replaced by an older queued record")
        var sameStepHistory = source
        sameStepHistory.checkpointStep = 9
        coherent.history.upsert(sameStepHistory)
        expect(coherent.recoverableTask(source.id)?.subtasks?.first?.completed == true,
               "Equal-step checkpoints select the newer full record by update time")

        let queueOnly = try make("evicted-history")
        var stoppedQueued = newerQueue; stoppedQueued.outcome = .stopped
        try queueOnly.taskQueue.append(.init(record: stoppedQueued, settings: queueOnly.settings, step: 9, started: true, state: .stopped))
        try queueOnly.taskQueue.append(.init(record: foreign, settings: queueOnly.settings, state: .waiting))
        let beforeQueueOnly = ModelProbe.calls
        expect(queueOnly.history.records.isEmpty && queueOnly.recoverableTask(source.id)?.id == source.id && ModelProbe.calls == beforeQueueOnly,
               "A stopped queued task stays discoverable even after its history entry has been evicted")
        expect(queueOnly.continueTask(source.id), "A queue-only stopped record supports explicit single-task continuation")
        try await settled(queueOnly)
        expect(queueOnly.engine.currentRecord?.id == source.id && queueOnly.engine.currentStep == 10 && queueOnly.engine.currentRecord?.subtasks?.first?.completed == true,
               "Queue-only continuation preserves exact identity, steps and confirmed completion evidence")
        expect(!queueOnly.queueRunning && queueOnly.taskQueue.items[1].state == .waiting && ModelProbe.calls == beforeQueueOnly + 1,
               "Queue-only recovery never starts or changes the next queued task")
        queueOnly.engine.stop(); try await settled(queueOnly)
        let stoppedAttempt = queueOnly.engine.runMetrics?.snapshot.id
        expect(queueOnly.retryTask(source.id), "The same queue-only task can be retried after explicit stop")
        try await settled(queueOnly)
        expect(queueOnly.engine.currentRecord?.id == source.id && queueOnly.engine.runMetrics?.snapshot.id != stoppedAttempt && !queueOnly.queueRunning,
               "Queue-only retry gets a new attempt while preserving task deduplication scope and queue isolation")
        queueOnly.engine.stop(); try await settled(queueOnly)
        let unresolved = try make("unresolved"); unresolved.history.upsert(source)
        unresolved.tools.unresolved.insert(source.id)
        let beforeUnresolved = ModelProbe.calls
        expect(!unresolved.retryTask(source.id) && !unresolved.continueTask(source.id) && ModelProbe.calls == beforeUnresolved,
               "A task with unknown write receipts cannot be revived through either recovery button")
        expect(unresolved.tools.unresolved.contains(source.id) && unresolved.engine.currentRecord == nil,
               "Rejected recovery preserves the original receipt and performs no execution")
        unresolved.tools.unresolved = []; unresolved.tools.unreadable = true
        expect(!unresolved.continueTask(source.id) && unresolved.notice.contains("回执"),
               "Unreadable receipt storage requires review before recovery")
        let denied = try make("consent"); denied.history.upsert(source)
        PrivacyConsent.revoke()
        let calls = ModelProbe.calls
        expect(!denied.retryTask(source.id) && denied.showPreparation && ModelProbe.calls == calls,
               "Recovery adopts current recipient consent instead of historical configuration authority")
        PrivacyConsent.grant(vm.settings)
        let evidenceVM = try make("fresh-task-evidence")
        let evidenceID = UUID()
        var evidenceVersion = "first-verified-ledger"
        var evidenceScopes: [UUID] = []
        evidenceVM.engine.systemToolEvidence = { id in
            evidenceScopes.append(id)
            return evidenceVersion
        }
        evidenceVM.engine.systemTool = { _, _ in
            evidenceVersion = "updated-verified-ledger"
            return "native receipt"
        }
        let firstEvidenceCall = ModelProbe.calls + 1
        ModelProbe.actionProvider = { call in
            call == firstEvidenceCall
                ? AgentAction(kind: .system_tool, text: #"{"operation":"calendar_search","start":"2026-10-04T00:00:00+08:00","end":"2026-10-05T00:00:00+08:00"}"#, reason: "one offline tool")
                : AgentAction(kind: .finish, reason: "offline evidence complete")
        }
        evidenceVM.engine.start(task: "Inspect fresh task evidence", settings: evidenceVM.settings, taskID: evidenceID)
        try await settled(evidenceVM)
        expect(ModelProbe.taskContexts.suffix(2).first?.contains("first-verified-ledger") == true && ModelProbe.taskContexts.last?.contains("updated-verified-ledger") == true,
               "Actual engine refreshes host evidence after a tool instead of keeping a compressed or stale inventory")
        expect(evidenceScopes == [evidenceID, evidenceID], "Every evidence request is bound to the running task identity")
        ModelProbe.actionProvider = nil; ModelProbe.action = AgentAction(kind: .finish, reason: "new task")
        let nextEvidenceID = UUID()
        evidenceVersion = "new-task-ledger"
        evidenceVM.engine.start(task: "A separate task", settings: evidenceVM.settings, taskID: nextEvidenceID)
        try await settled(evidenceVM)
        expect(evidenceScopes.last == nextEvidenceID && ModelProbe.taskContexts.last == "new-task-ledger",
               "A new task gets its own provider scope without the previous task's model context")
        // Exercise the production export with persisted failure state, exact
        // source text, and a deliberately bounded historical archive.
        var exportMemory = TaskContextMemory()
        let archivedLogs = (1...80).map {
            AgentLogEntry(step: $0, title: "工具回执", detail: String(repeating: "精确原文 e\u{301} / é\t", count: 80))
        }
        exportMemory.absorb(archivedLogs)
        var exportSource = PhoneTaskRecord(title: "导出测试", goal: "原任务 e\u{301} / é\n\t第二行 👨‍👩‍👧‍👦", outcome: .failed,
            summary: "模型请求失败：HTTP 429", logs: Array(archivedLogs.suffix(2)),
            amendments: [.init(text: "补充原文\n保留")], subtasks: [.init(goal: "未确定的提交，不能重放")],
            contextMemory: exportMemory, checkpointStep: 81, attemptStartStep: 0)
        let snapshotEncoder = JSONEncoder(); snapshotEncoder.outputFormatting = [.sortedKeys]
        let sourceBytes = try snapshotEncoder.encode(exportSource)
        let exportDate = Date(timeIntervalSinceReferenceDate: 123456789.125)
        let exportBytes = try TaskRecordExport.data(record: exportSource, exportedAt: exportDate)
        let exported = try JSONDecoder().decode(TaskRecordExport.Document.self, from: exportBytes)
        let exportedRecordBytes = try snapshotEncoder.encode(exported.record)
        expect(exportedRecordBytes == sourceBytes, "Export round-trips the entire exact persisted record, Unicode, amendments, unknown subtasks and errors")
        let sourceAfterExport = try snapshotEncoder.encode(exportSource)
        expect(sourceAfterExport == sourceBytes, "Export is a read-only value snapshot with no task mutation")
        expect(exported.exportedAt == exportDate && exported.schemaVersion == 1,
               "Export retains its timestamp and schema identity without losing fractional seconds")
        expect(exported.coverage.rawLogCount == 2 && exported.coverage.firstRawLogStep == 79 && exported.coverage.lastRawLogStep == 80,
               "Coverage reports retained raw logs rather than inventing missing historical steps")
        expect(exported.coverage.compactedSourceEntryCount == 80 && exported.coverage.retainedCompactedEntryCount == exportMemory.retainedEntryCount && exported.coverage.truncatedCompactedCharacters == exportMemory.truncatedCharacterCount,
               "Export discloses actual archive and truncation counts alongside the retained archive")
        expect(!exported.coverage.fullHistoricalTranscriptGuaranteed && !exported.coverage.notIncluded.isEmpty,
               "A retained snapshot cannot be advertised as a guaranteed complete transcript or independent verification")
        for outcome in [TaskOutcome.running, .paused, .needsUser, .completed, .failed, .stopped, .interrupted, .preview] {
            exportSource.outcome = outcome
            let data = try TaskRecordExport.data(record: exportSource, exportedAt: exportDate)
            let decoded = try JSONDecoder().decode(TaskRecordExport.Document.self, from: data)
            expect(decoded.record.outcome == outcome && decoded.record.id == exportSource.id && decoded.record.checkpointStep == 81,
                   "Export preserves \(outcome) and original task identity without restarting or relabelling it")
        }
        let emptyExport = try TaskRecordExport.data(record: PhoneTaskRecord(title: "空记录", goal: "尚无日志"))
        let emptyDocument = try JSONDecoder().decode(TaskRecordExport.Document.self, from: emptyExport)
        expect(emptyDocument.coverage.rawLogCount == 0 && emptyDocument.coverage.firstRawLogStep == nil && emptyDocument.coverage.lastRawLogStep == nil && emptyDocument.coverage.compactedSourceEntryCount == 0,
               "An empty task does not acquire fake history or a fake step range during export")
        let nativeVM = try make("native-independent")
        ModelProbe.action = AgentAction(kind: .finish, reason: "native recovery completed"); ModelProbe.delay = 100_000_000
        nativeVM.engine.start(task: "another active task", settings: nativeVM.settings)
        let mainIdentity = nativeVM.engine.currentRecord!.id
        var nativeSource = source; nativeSource.id = UUID(); nativeSource.executionLane = "native"
        nativeSource.goal = "查看本 App 的闹钟"
        // Recovery may finish without repeating an already completed SDK read,
        // but a model finish/reason alone is not evidence. Use the same strict
        // host receipt parser as production, with synthetic OS data only.
        let priorNativeRead = "[]\n本 App 闹钟总数：0，返回前 20 项"
        var priorNativeEvidence = TaskCompletionEvidence(goal: nativeSource.effectiveGoal)
        guard let nativeReadProof = TaskCompletionEvidence.successfulTool(operation: "alarm_list", result: priorNativeRead,
            title: nil, start: nil, end: nil, query: nil, artifactReference: nil, content: nil,
            eventID: nativeSource.id.uuidString + ":prior-read") else { preconditionFailure("Synthetic native SDK receipt must pass the production evidence parser") }
        priorNativeEvidence.add(nativeReadProof); nativeSource.completionEvidence = priorNativeEvidence
        nativeVM.history.upsert(nativeSource)
        expect(nativeVM.continueTask(nativeSource.id) && nativeVM.engine.running && nativeVM.engine.currentRecord?.id == mainIdentity,
               "Native history recovery starts independently without replacing or pausing the active main task")
        let nativeDeadline = Date().addingTimeInterval(5)
        while nativeVM.backgroundTasks.record(nativeSource.id)?.outcome != .completed {
            precondition(Date() < nativeDeadline); try await Task.sleep(for: .milliseconds(1))
        }
        expect(nativeVM.backgroundTasks.record(nativeSource.id)?.id == nativeSource.id && nativeVM.history.records.first(where: { $0.id == nativeSource.id })?.executionLane == "native",
               "Native recovery returns its own result and preserves lane/identity in history")
        expect(nativeVM.backgroundTasks.record(nativeSource.id)?.completionEvidence?.tools.map(\.operation) == ["alarm_list"],
               "Native recovery retains the original actual-format read evidence instead of accepting a bare model finish")
        try await settled(nativeVM)
        var blockedNative = nativeSource; blockedNative.id = UUID(); nativeVM.history.upsert(blockedNative)
        nativeVM.tools.unresolved.insert(blockedNative.id)
        expect(!nativeVM.continueTask(blockedNative.id) && !nativeVM.backgroundTasks.contains(blockedNative.id),
               "Native recovery cannot bypass an unresolved write receipt")
        ModelProbe.delay = 0
        let fifoHistory = try make("screen-fifo-history")
        fifoHistory.settings.toolsOnly = false
        var oldScreen = source; oldScreen.executionLane = "screen"
        var newScreen = newerQueue; newScreen.id = oldScreen.id; newScreen.executionLane = "screen"
        let beforeSelected = PhoneTaskRecord(title: "Earlier screen task", goal: "Earlier screen task", outcome: .paused)
        try fifoHistory.taskQueue.append(.init(record: beforeSelected, settings: fifoHistory.settings))
        try fifoHistory.taskQueue.append(.init(record: oldScreen, settings: fifoHistory.settings, step: 4, started: true, state: .suspended))
        fifoHistory.history.upsert(newScreen)
        let callsBeforeFIFO = ModelProbe.calls
        expect(fifoHistory.continueTask(oldScreen.id) && fifoHistory.engine.currentRecord == nil && ModelProbe.calls == callsBeforeFIFO,
               "A history-card continue for a queued screen task only restores its queue position")
        expect(fifoHistory.taskQueue.items.map(\.id) == [beforeSelected.id,oldScreen.id] && fifoHistory.taskQueue.items[1].step == 9 && fifoHistory.taskQueue.items[1].record.subtasks?.first?.completed == true,
               "Queue recovery preserves FIFO and the newer complete history checkpoint including its step")
        expect(fifoHistory.retryTask(oldScreen.id) && fifoHistory.taskQueue.items[1].record.attemptStartStep == 9 && ModelProbe.calls == callsBeforeFIFO,
               "Explicit queued retry renews only the selected attempt budget without secretly executing or moving it")
        checks += try RecoveryReceiptChecks.run()
        print("TaskRecovery controller checks passed (\(checks) checks; full actual engine and stores, synthetic platform/model/input)")
    }
}
