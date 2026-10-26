import Foundation
import Combine

@main struct TaskCompletionChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        func settled(_ engine: AgentEngine) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !engine.executionSettled {
                precondition(Date() < deadline, "Completion fixture timed out")
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        var config = AgentSettings(); config.startDelay = 0; config.stepInterval = 0.4
        config.continuousExecution = true; config.systemToolsEnabled = true; config.toolsOnly = true
        config.confirmEachStep = false; config.useMemories = false
        PrivacyConsent.grant(config); defer { PrivacyConsent.revoke() }
        let title = "提交周报", start = "2026-10-27T09:00:00+08:00"
        let goal = "创建明天上午9点的提醒，内容是提交周报"
        let reminder = SystemToolRequest(operation: .reminder_create, title: title, start: start)
        func tool(_ request: SystemToolRequest) throws -> AgentAction {
            AgentAction(kind: .system_tool, text: String(decoding: try JSONEncoder().encode(request), as: UTF8.self), reason: "离线工具计划")
        }
        func receipt(_ title: String = "提交周报", due: String? = "2026-10-27T09:00:00+08:00") throws -> String {
            try NativeEventWriteReceipt(operation: .reminder, receiptID: UUID(), systemItemID: "synthetic-system-id", collectionID: "synthetic-list-id",
                title: title, collectionName: "离线提醒列表", due: due).serialized()
        }
        let finish = AgentAction(kind: .finish, text: "已创建明天上午9点的提醒", reason: "模型声明结束")
        let contact = SystemToolRequest(operation: .contact_search, query: "Alice")
        let contactReceipt = "{\"matches\":[{\"name\":\"Alice\"}],\"matched_count\":1,\"returned_count\":1,\"truncated\":false}"
        var toolCalls = 0
        func engine(script: [AgentAction], result: String = "unused", visual: Bool = false) -> AgentEngine {
            ModelProbe.calls = 0; ModelProbe.delay = 0; ModelProbe.onRequest = nil
            ModelProbe.actionProvider = { script[min($0 - 1, script.count - 1)] }
            toolCalls = 0
            let engine = AgentEngine(capture: CaptureService(), executor: MouseExecutor(), ownsScreenInput: visual)
            engine.metricsDirectory = nil
            engine.systemTool = { _, _ in toolCalls += 1; return result }
            return engine
        }
        let zero = engine(script: [finish]); zero.start(task: goal, settings: config); try await settled(zero)
        expect(zero.phase == .needsUser && zero.currentRecord?.outcome == .needsUser && toolCalls == 0 && zero.currentRecord?.nativeResults == nil,
            "The original full-engine reproduction cannot turn zero tools into a completed reminder")
        expect(zero.currentRecord?.summary.contains("尚无匹配") == true && zero.canResume,
            "Unverified finish retains an explicit resumable task instead of silently failing or claiming success")

        let wrong = engine(script: [try tool(contact), finish], result: contactReceipt)
        wrong.start(task: goal, settings: config); try await settled(wrong)
        expect(wrong.phase == .needsUser && toolCalls == 1, "An unrelated successful contact read cannot satisfy reminder creation")

        let rawReceipt = try receipt()
        let success = engine(script: [try tool(reminder), finish], result: rawReceipt)
        success.start(task: goal, settings: config); try await settled(success)
        expect(success.phase == .completed && toolCalls == 1 && success.currentRecord?.completionEvidence?.tools.map(\.operation) == ["reminder_create"],
            "A matching structured EventKit write receipt permits native completion")
        expect(success.currentRecord?.nativeResults?.first?.systemObjectID == "synthetic-system-id", "Real host receipt identity remains in the result card")
        var recovered = success.currentRecord!; recovered.outcome = .paused
        let restored = engine(script: [finish])
        try restored.recover(record: recovered, settings: config, mode: .continueTask); try await settled(restored)
        expect(restored.phase == .completed && toolCalls == 0, "Persisted host completion evidence survives recovery without repeating the write")

        var legacy = recovered; legacy.completionEvidence = nil
        let legacyEngine = engine(script: [finish])
        try legacyEngine.recover(record: legacy, settings: config, mode: .continueTask); try await settled(legacyEngine)
        expect(legacyEngine.phase == .completed && toolCalls == 0, "Strict legacy system-ID cards remain recoverable without a duplicate write")
        legacy.nativeResults = nil; legacy.logs = [AgentLogEntry(step: 1, title: "工具回执", detail: rawReceipt)]
        let logOnly = engine(script: [finish])
        try logOnly.recover(record: legacy, settings: config, mode: .continueTask); try await settled(logOnly)
        expect(logOnly.phase == .needsUser && toolCalls == 0, "A model-facing log string alone never establishes completed system work")
        let ledger = engine(script: [finish]); ledger.completedToolReceipts = { _ in [rawReceipt] }
        try ledger.recover(record: legacy, settings: config, mode: .continueTask); try await settled(ledger)
        expect(ledger.phase == .completed && toolCalls == 0, "A task-bound completed durable host receipt can recover a cancelled return")
        let ledgerThenRead = engine(script: [try tool(contact), finish], result: contactReceipt)
        ledgerThenRead.completedToolReceipts = { _ in [rawReceipt] }
        try ledgerThenRead.recover(record: legacy, settings: config, mode: .continueTask); try await settled(ledgerThenRead)
        expect(ledgerThenRead.phase == .completed && toolCalls == 1 && ledgerThenRead.currentRecord?.completionEvidence?.tools.count == 2,
            "Legacy host write evidence is restored before a remaining read and survives that read")

        let badTitle = engine(script: [try tool(reminder), finish], result: try receipt("错误标题"))
        badTitle.start(task: goal, settings: config); try await settled(badTitle)
        expect(badTitle.phase == .needsUser, "A tool receipt whose actual title contradicts its request is not completion evidence")
        let badTime = engine(script: [try tool(reminder), finish], result: try receipt(due: "2026-10-27T08:00:00+08:00"))
        badTime.start(task: goal, settings: config); try await settled(badTime)
        expect(badTime.phase == .needsUser, "A returned system time contradicting the actual request blocks completion")

        var changed = recovered; changed.amendments = [.init(text: "改成后天下午3点提醒我提交月报")]
        let changedEngine = engine(script: [finish]); changedEngine.completedToolReceipts = { _ in [rawReceipt] }
        try changedEngine.recover(record: changed, settings: config, mode: .continueTask); try await settled(changedEngine)
        expect(changedEngine.phase == .needsUser, "Old evidence cannot complete changed user requirements")
        changedEngine.resume(); try await settled(changedEngine)
        expect(changedEngine.phase == .needsUser, "A second finish cannot re-import old task receipts after requirement changes")

        let alarmList = SystemToolRequest(operation: .alarm_list)
        let read = engine(script: [try tool(alarmList), finish], result: "[]\n本 App 闹钟总数：0，返回前 20 项")
        read.start(task: "查看本 App 的闹钟", settings: config); try await settled(read)
        expect(read.phase == .completed && toolCalls == 1, "A valid read receipt can finish without GUI input")
        for (readGoal, operation) in [("查看音乐播放状态", "music_status"), ("查找我上次播放的歌曲", "music_search"), ("查看日历中创建的日程", "calendar_search")] {
            var evidence = TaskCompletionEvidence(goal: readGoal)
            evidence.add(.init(operation: operation, receiptID: "synthetic", title: nil, start: nil, end: nil, resultSHA256: String(repeating: "a", count: 64)))
            expect(TaskCompletionPolicy.decide(goal: readGoal, toolsOnly: true, evidence: evidence) == .tools,
                "Read intent is not converted into a mutation merely by mentioning an action: " + readGoal)
        }
        for readGoal in ["查询购买记录", "查看发送状态", "查一下昨天的评论", "不用发送，只查看联系人"] {
            var evidence = TaskCompletionEvidence(goal: readGoal); evidence.observe(confirmedAt: Date())
            if readGoal.contains("联系人") { evidence.add(.init(operation: "contact_search", receiptID: "synthetic", title: nil, start: nil, end: nil, resultSHA256: String(repeating: "a", count: 64))) }
            let decision = TaskCompletionPolicy.decide(goal: readGoal, toolsOnly: false, evidence: evidence)
            expect(decision == .observed || decision == .tools, "Read/negated operation wording preserves legitimate current-screen reads: " + readGoal)
        }
        for (readGoal, operation) in [("不要创建提醒，只查看已有提醒", "reminder_search"),
                                     ("查看已有提醒", "reminder_search"),
                                     ("创建提醒\n\n用户后续补充（与前文冲突时，以较新的明确要求为准）：\n1. 不要创建提醒，改为查询联系人", "contact_search")] {
            var evidence = TaskCompletionEvidence(goal: readGoal)
            evidence.add(.init(operation: operation, receiptID: "synthetic", title: nil, start: nil, end: nil, resultSHA256: String(repeating: "a", count: 64)))
            expect(TaskCompletionPolicy.decide(goal: readGoal, toolsOnly: true, evidence: evidence) == .tools,
                "Read-only constraints/latest explicit operation corrections preserve supported behavior: " + readGoal)
        }
        let mixedGoal = "查联系人然后发送消息"
        var mixedEvidence = TaskCompletionEvidence(goal: mixedGoal); mixedEvidence.observe(confirmedAt: Date())
        mixedEvidence.add(.init(operation: "contact_search", receiptID: "synthetic", title: nil, start: nil, end: nil, resultSHA256: String(repeating: "a", count: 64)))
        if case .needsUser = TaskCompletionPolicy.decide(goal: mixedGoal, toolsOnly: false, evidence: mixedEvidence) { checks += 1 }
        else { preconditionFailure("A read clause must not authorize completion of a later send clause") }

        var previewConfig = config; previewConfig.previewOnly = true
        let preview = engine(script: [finish]); preview.start(task: goal, settings: previewConfig); try await settled(preview)
        expect(preview.phase == .preview && toolCalls == 0 && preview.currentRecord?.completionEvidence?.tools.isEmpty != false,
            "Preview finish remains a plan and does not become successful execution")
        let stopped = engine(script: [finish]); ModelProbe.delay = 200_000_000
        stopped.start(task: goal, settings: config); try await Task.sleep(nanoseconds: 10_000_000); stopped.stop(); try await settled(stopped)
        expect(stopped.phase == .stopped && toolCalls == 0, "Stop still owns the terminal state when a finish is in flight")

        var visualConfig = config; visualConfig.toolsOnly = false
        let screenRead = engine(script: [finish], visual: true)
        screenRead.start(task: "查看当前画面并告诉我显示内容", settings: visualConfig); try await settled(screenRead)
        expect(screenRead.phase == .completed && screenRead.executor.actions.isEmpty && screenRead.state.contains("已观察当前画面"),
            "A legitimate current-screen reading task needs a fresh observation, not an artificial mouse click")
        let screenCreate = engine(script: [finish], visual: true)
        screenCreate.start(task: goal, settings: visualConfig); try await settled(screenCreate)
        expect(screenCreate.phase == .needsUser && screenCreate.executor.actions.isEmpty, "Observing the screen cannot prove a requested creation happened")
        let tap = AgentAction(kind: .tap, x: 0.5, y: 0.5, reason: "离线点击")
        let visualSuccess = engine(script: [tap, finish], visual: true)
        visualSuccess.start(task: "点击当前按钮", settings: visualConfig); try await settled(visualSuccess)
        expect(visualSuccess.phase == .completed && visualSuccess.state.contains("尚未独立核验") && visualSuccess.currentRecord?.completionEvidence?.postInputObservations == 1,
            "A real dispatched action and subsequent frame retain observed completion without claiming independent business verification")

        let storage = engine(script: [try tool(reminder), finish], result: rawReceipt)
        var writable = true; storage.executionPersistenceReady = { writable }
        ModelProbe.onRequest = { writable = false }
        storage.start(task: goal, settings: config); try await settled(storage)
        expect(storage.phase == .paused && toolCalls == 0, "Persistence failure after inference pauses before tool dispatch")
        ModelProbe.onRequest = nil

        let terminalStore = engine(script: [try tool(reminder), finish], result: rawReceipt)
        var publishedPhases: [AgentPhase] = [], terminalCommitAttempts = 0
        var uncommittedProjection = false, failureCallbacks = 0
        terminalStore.onRecord = { if $0.outcome == .paused { uncommittedProjection = true } }
        terminalStore.onPersistenceFailure = { record in
            if record.outcome == .paused { failureCallbacks += 1 }
        }
        let phaseSink = terminalStore.$phase.sink { publishedPhases.append($0) }
        terminalStore.persistRecord = { candidate in
            if candidate.outcome == .completed {
                terminalCommitAttempts += 1
                expect(terminalStore.phase != .completed && terminalStore.taskIndicator != .completed,
                    "Durable commit observes no prematurely published success phase or accessory indicator")
                return false
            }
            return true
        }
        terminalStore.start(task: goal, settings: config); try await settled(terminalStore)
        expect(terminalCommitAttempts == 1 && terminalStore.phase == .paused && !publishedPhases.contains(.completed)
            && terminalStore.taskIndicator != .completed && terminalStore.currentRecord?.completionEvidence?.tools.count == 1,
            "A failed final durable commit pauses, retains actual evidence and never emits success to UI/voice")
        expect(failureCallbacks == 1 && !uncommittedProjection,
            "A failed commit reaches only the volatile failure callback, never committed onRecord projections")
        withExtendedLifetime(phaseSink) {}

        let reentrant = engine(script: [try tool(reminder), finish], result: rawReceipt)
        var cancelledAtCommit = false
        reentrant.persistRecord = { candidate in
            if candidate.outcome == .completed && !cancelledAtCommit { cancelledAtCommit = true; reentrant.stop() }
            return true
        }
        reentrant.start(task: goal, settings: config); try await settled(reentrant)
        if !cancelledAtCommit || reentrant.phase != .stopped || reentrant.currentRecord?.outcome != .stopped || reentrant.taskIndicator == .completed {
            print("Reentrant completion fixture: intercepted=\(cancelledAtCommit), phase=\(reentrant.phase.rawValue), outcome=\(reentrant.currentRecord?.outcome.rawValue ?? "none"), indicator=\(reentrant.taskIndicator)")
            fflush(stdout)
        }
        expect(cancelledAtCommit && reentrant.phase == .stopped && reentrant.currentRecord?.outcome == .stopped && reentrant.taskIndicator != .completed,
            "A synchronous Stop during persistence cannot be overwritten by the old completion candidate")

        let subtask = engine(script: [finish])
        subtask.start(task: goal, settings: config, subtasks: ["创建提交周报提醒"])
        let subtaskID = subtask.currentRecord!.subtasks!.first!.id
        ModelProbe.actionProvider = { _ in AgentAction(kind: .complete_subtask, text: subtaskID.uuidString, reason: "模型声称已完成") }
        try await settled(subtask)
        expect(subtask.phase == .needsUser && subtask.currentRecord?.subtasks?.first?.completed == false,
            "Model subtask reason cannot replace host completion evidence")
        ModelProbe.actionProvider = nil; ModelProbe.onRequest = nil; ModelProbe.delay = 0
        print("PASS: \(checks) full production Engine completion-evidence checks; synthetic model/OS only")
    }
}
