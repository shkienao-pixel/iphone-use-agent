import Foundation

@MainActor private final class RecoveryPendingHarness: PhoneHarnessDriving {
    var hasPendingReview = true
    func context(for frame: ScreenFrame) async throws -> String { "pending receipt" }
    func didExecute(_ action: AgentAction, frame: ScreenFrame) async {}
    func execute(_ request: PhoneHarnessRequest, frame: ScreenFrame, mappedHome: Bool,
                 nextFrame: @escaping @MainActor (Date) async throws -> ScreenFrame) async throws -> PhoneHarnessReceipt {
        throw AgentError.message("Pending business result must not execute")
    }
}

@MainActor enum TaskRecoveryChecks {
    static func run(directory: URL, settings original: AgentSettings) async throws -> Int {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) { precondition(condition(), label); checks += 1 }
        func settled(_ engine: AgentEngine) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !engine.executionSettled {
                precondition(Date() < deadline, "Recovery fixture timed out")
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        func rejects(_ work: () throws -> Void, _ label: String) { do { try work(); preconditionFailure(label) } catch { checks += 1 } }
        var settings = original
        settings.toolsOnly = true; settings.systemToolsEnabled = true; settings.continuousExecution = false
        settings.maxSteps = 3; settings.confirmEachStep = false; settings.model = "current-recovery-model"
        PrivacyConsent.grant(settings)
        ModelProbe.calls = 0; ModelProbe.delay = 0; ModelProbe.onRequest = nil; ModelProbe.actionProvider = nil
        ModelProbe.action = AgentAction(kind: .ask_user, reason: "Check current state before any side effect")
        let capture = CaptureService(), executor = MouseExecutor()
        capture.running = false; executor.ble.ready = false
        let engine = AgentEngine(capture: capture, executor: executor)
        engine.systemTool = { _, _ in "offline receipt" }
        var source = PhoneTaskRecord(title: "Historical failed task", goal: "Finish only the remaining work", outcome: .failed,
            summary: "provider unavailable", logs: [.init(step: 42, title: "工具回执", detail: "Completed write receipt; do not repeat")],
            amendments: [.init(text: "Keep all later constraints")],
            subtasks: [.init(goal: "Already confirmed", completed: true, evidence: "Receipt A"), .init(goal: "Remaining")],
            checkpointStep: 42, attemptStartStep: 40)
        let sourceID = source.id, completedID = source.subtasks![0].id
        let path = directory.appendingPathComponent("recovery-history.json")
        let store = TaskHistoryStore(url: path); store.upsert(source)
        let reloaded = TaskHistoryStore(url: path).records[0]
        expect(reloaded.checkpointStep == 42 && reloaded.attemptStartStep == 40, "Exact recovery checkpoint and attempt budget survive disk reload")
        expect(ModelProbe.calls == 0 && !engine.hasCurrentTask, "Loading failure history never restores execution authority")
        try engine.recover(record: reloaded, settings: settings, mode: .continueTask)
        let attempt = engine.runMetrics!.snapshot.id
        try await settled(engine)
        expect(engine.currentRecord?.id == sourceID && engine.currentStep == 43, "Historical continuation retains identity and cumulative steps")
        expect(engine.currentRecord?.attemptStartStep == 40 && engine.currentRecord?.checkpointStep == 43, "Continue preserves the original attempt's consumed budget")
        expect(engine.currentRecord?.subtasks?[0].id == completedID && engine.currentRecord?.subtasks?[0].completed == true, "Confirmed subtask ledger is never reset by recovery")
        expect(engine.currentRecord?.amendments?.first?.text == source.amendments?.first?.text && engine.logs.contains(where: { $0.id == source.logs[0].id }), "Historical amendments and receipts remain attached to their original task")
        expect(engine.currentSettings?.model == settings.model && engine.currentSettings?.confirmEachStep == false, "Recovery uses current model and confirmation preferences")
        expect(ModelProbe.goals.last?.contains("已有完成记录不得重做") == true && executor.actions.isEmpty, "The next plan sees the confirmed ledger without replaying old input")
        let exhausted = engine.currentRecord!
        rejects({ try engine.recover(record: exhausted, settings: settings, mode: .continueTask) }, "Continuing an exhausted finite attempt cannot regain its budget")
        expect(ModelProbe.calls == 1 && engine.currentRecord?.checkpointStep == 43, "Rejected continuation dispatches no new model or task action")
        try engine.recover(record: exhausted, settings: settings, mode: .retry)
        let retriedAttempt = engine.runMetrics!.snapshot.id
        try await settled(engine)
        expect(retriedAttempt != attempt && engine.currentRecord?.id == sourceID, "Retry opens a fresh metrics attempt while retaining the tool deduplication identity")
        expect(engine.currentRecord?.attemptStartStep == 43 && engine.currentStep == 44, "Retry renews only the attempt budget while cumulative log steps remain monotonic")
        expect(engine.currentRecord?.subtasks?[0].completed == true && engine.logs.contains(where: { $0.title == "重试任务" }), "Retry replans from the start without discarding confirmed effects")
        var foreign = source; foreign.id = UUID()
        rejects({ try engine.recover(record: foreign, settings: settings, mode: .retry) }, "Selecting a different archived task cannot replace another retained execution session")
        expect(engine.currentRecord?.id == sourceID && ModelProbe.calls == 2, "Foreign task rejection preserves both identity and ongoing attempt")
        engine.stop(); try await settled(engine)
        expect(!engine.canResume && !engine.hasCurrentTask && engine.phase == .stopped, "Stop still revokes the old session's automatic resume authority")
        let stopped = engine.currentRecord!, oldSession = engine.activityControlSessionID
        try engine.recover(record: stopped, settings: settings, mode: .continueTask)
        try await settled(engine)
        expect(engine.currentRecord?.id == sourceID && engine.currentStep == 45 && engine.activityControlSessionID != oldSession, "An explicit continue can recover a stopped task with a fresh control session")
        engine.stop(); try await settled(engine)
        var invalid = source; invalid.checkpointStep = -1
        rejects({ try engine.recover(record: invalid, settings: settings, mode: .retry) }, "Invalid checkpoints cannot authorize execution")
        var completed = source; completed.outcome = .completed
        rejects({ try engine.recover(record: completed, settings: settings, mode: .retry) }, "Recovery buttons cannot restart completed tasks through this API")
        let pending = RecoveryPendingHarness(); engine.phoneHarness = pending
        rejects({ try engine.recover(record: source, settings: settings, mode: .retry) }, "Unknown prior business submission blocks recovery before any new observation or input")
        expect(ModelProbe.calls == 3 && executor.actions.isEmpty, "Pending business review never triggers a retry send")
        engine.phoneHarness = nil

        // Real engine + request decoder; the receipt closure models the same
        // production contract (stable task ID + canonical tool request).
        var writes: [UUID: Int] = [:], receivedIDs: [UUID] = []
        let request = SystemToolRequest(operation: .reminder_create, title: "Recovery idempotency fixture")
        let encoded = String(data: try JSONEncoder().encode(request), encoding: .utf8)!
        var tools = settings; tools.continuousExecution = true
        ModelProbe.calls = 0
        ModelProbe.actionProvider = { call in call % 2 == 1
            ? AgentAction(kind: .system_tool, text: encoded, reason: "Same exact confirmed tool request")
            : AgentAction(kind: .ask_user, reason: "Stop for fixture review") }
        engine.systemTool = { id, _ in
            receivedIDs.append(id)
            if writes[id] != nil { return "重复请求已跳过；之前的回执：fixture" }
            writes[id] = 1; return "Completed write fixture"
        }
        source.checkpointStep = 0; source.attemptStartStep = 0
        try engine.recover(record: source, settings: tools, mode: .retry); try await settled(engine)
        let afterTool = engine.currentRecord!
        try engine.recover(record: afterTool, settings: tools, mode: .retry); try await settled(engine)
        expect(receivedIDs == [sourceID, sourceID] && writes[sourceID] == 1, "A retry passes the same task scope to the tool receipt layer, so a confirmed create is not duplicated")
        expect(engine.logs.filter({ $0.title == "工具回执" }).count >= 3, "Both real prior receipt and skipped-repeat receipt remain in the recovery timeline")
        engine.stop(); try await settled(engine)
        PrivacyConsent.revoke()
        rejects({ try engine.recover(record: source, settings: tools, mode: .continueTask) }, "Current recipient consent is checked again before historical data reaches the model")
        expect(ModelProbe.calls == 4, "Revoked consent cannot cause an additional inference")
        PrivacyConsent.grant(original)
        ModelProbe.calls = 0; ModelProbe.actionProvider = nil; ModelProbe.onRequest = nil; ModelProbe.delay = 0
        return checks
    }
}
