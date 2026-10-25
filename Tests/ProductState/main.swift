import Foundation

@main struct ProductStateChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
            precondition(condition(), description); checks += 1
        }
        func voiceRoute(current: Bool = false, pending: Int = 0, queueRunning: Bool = false,
                        engineRunning: Bool = false, switching: Bool = false, releasing: Bool = false,
                        voicePending: Bool = false, manualBusy: Bool = false, calibrating: Bool = false) -> VoiceTaskRequestRoute {
            VoiceTaskRequestRouter.route(hasCurrentTask: current, pendingTaskCount: pending,
                                         queueRunning: queueRunning, engineRunning: engineRunning,
                                         queueSwitching: switching, engineReleasing: releasing,
                                         voicePending: voicePending, manualBusy: manualBusy,
                                         calibrating: calibrating)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneAgentChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "PhoneAgentConsentChecks-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite); PrivacyConsent.revoke() }
        var settings = AgentSettings(); settings.startDelay = 0; settings.stepInterval = 0.5
        expect(!PrivacyConsent.allowed(settings, defaults: defaults), "Consent must be explicit")
        PrivacyConsent.grant(settings, defaults: defaults)
        expect(PrivacyConsent.allowed(settings, defaults: defaults), "Authorized recipient should be usable")
        var changed = settings; changed.endpoint = "https://other.example/v1/chat/completions"
        expect(!PrivacyConsent.allowed(changed, defaults: defaults), "Changed recipient needs new consent")
        changed = settings; changed.providerName = "Changed recipient"
        expect(!PrivacyConsent.allowed(changed, defaults: defaults), "Provider name change invalidates consent")
        defaults.set(Data("corrupt".utf8), forKey: "agent.aiConsent.v1")
        expect(!PrivacyConsent.allowed(settings, defaults: defaults), "Malformed grants fail closed")
        PrivacyConsent.grant(settings, defaults: defaults); PrivacyConsent.revoke(defaults: defaults)
        expect(!PrivacyConsent.allowed(settings, defaults: defaults), "Revocation must take effect")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        object.removeValue(forKey: "providerName")
        let migrated = try JSONDecoder().decode(AgentSettings.self, from: JSONSerialization.data(withJSONObject: object))
        expect(migrated.endpoint == settings.endpoint && migrated.providerName == nil, "Old settings retain endpoint")

        let path = directory.appendingPathComponent("tasks.json")
        let store = TaskHistoryStore(url: path)
        let original = PhoneTaskRecord(title: "Original", goal: "Original goal", conversationReference: "VERBATIM-CURRENT-CHAT-REFERENCE")
        store.upsert(original); store.rename(original.id, title: "Renamed")
        expect(store.records[0].title == "Renamed", "Rename preserves identity")
        expect(store.records[0].goal == "Original goal", "Rename does not change task instructions")
        let reloaded = TaskHistoryStore(url: path)
        expect(reloaded.records[0].outcome == .interrupted, "Restart never restores an active task")
        expect(reloaded.records[0].id == original.id, "Stored task identity survives restart")
        expect(reloaded.records[0].conversationReference == original.conversationReference && reloaded.records[0].effectiveGoal == original.goal,
               "Restart retains selected conversation data separately from task instructions")
        for i in 0..<55 { store.upsert(PhoneTaskRecord(title: "Task \(i)", goal: "Offline")) }
        expect(store.records.count == 50, "History retention is bounded")
        let newest = store.records[0].id; store.remove(newest)
        expect(!store.records.contains { $0.id == newest }, "Delete persists")
        expect(TaskHistoryStore(url: path).records.count == 49, "Deletion survives reload")
        let corrupt = Data("broken document".utf8); try corrupt.write(to: path)
        let broken = TaskHistoryStore(url: path)
        expect(!broken.error.isEmpty, "Corrupt history shows a recoverable error")
        broken.upsert(original)
        let preserved = try Data(contentsOf: path)
        expect(preserved == corrupt, "Corrupt file must not be overwritten")
        broken.clear(); expect(broken.records.isEmpty && broken.error.isEmpty, "Explicit clear restores storage")
        broken.upsert(original); expect(broken.records.count == 1, "Storage works after clear")

        func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                precondition(Date() < deadline, "State transition timed out")
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let capture = CaptureService(), executor = MouseExecutor()
        let engine = AgentEngine(capture: capture, executor: executor)
        PrivacyConsent.revoke(); ModelProbe.calls = 0
        engine.start(task: "Offline task", settings: settings)
        expect(!engine.running && ModelProbe.calls == 0, "Missing consent blocks inference")
        PrivacyConsent.grant(settings)
        executor.actionDelay = 1_000_000_000
        ModelProbe.action = AgentAction(kind: .tap, x: 0.5, y: 0.5, reason: "Offline tap")
        let submissionID = UUID()
        engine.start(task: "Offline task", settings: settings, taskID: submissionID, conversationReference: "VERBATIM-CLARIFICATION-SOURCE")
        try await waitUntil { engine.phase == .acting }
        expect(engine.currentRecord?.id == submissionID, "A reserved submission identity reaches the actual engine record")
        expect(engine.runMetrics?.snapshot.taskID == submissionID, "Execution metrics use the same reserved submission identity")
        expect(ModelProbe.taskContexts.last?.contains("VERBATIM-CLARIFICATION-SOURCE") == true && ModelProbe.skillReferences.last == "VERBATIM-CLARIFICATION-SOURCE",
               "The real engine passes source grounding to the action context and skill selector without rewriting the task")
        engine.pause()
        expect(engine.phase == .paused && !engine.running, "Pause cancels execution")
        expect(engine.releasing, "Pause closes input before allowing resume")
        engine.resume()
        expect(ModelProbe.calls == 1, "Resume cannot race old release")
        try await waitUntil { !engine.releasing }
        expect(executor.ble.releases > 0 && engine.canResume, "Paused task becomes resumable after cleanup")
        let finalReport = "Verified item A and item B. Empty results cover visible data only.\nActual report retained in history."
        ModelProbe.action = AgentAction(kind: .finish, text: finalReport, reason: "Verified offline result")
        engine.resume()
        try await waitUntil { engine.phase == .completed && !engine.releasing }
        expect(executor.actions == [.tap], "Resume does not replay the interrupted action")
        expect(ModelProbe.calls == 2, "Resume obtains a new observation")
        expect(engine.currentRecord?.outcome == .completed, "Completion reaches the history record")
        expect(engine.state == finalReport && engine.currentRecord?.summary == finalReport,
               "The final report reaches visible state and durable task history instead of only a short caption")
        let reportRoundTrip = try JSONDecoder().decode(PhoneTaskRecord.self, from: JSONEncoder().encode(engine.currentRecord!))
        expect(reportRoundTrip.summary == finalReport, "The complete result survives history encoding")
        expect(!engine.canResume, "Completed task cannot resume")
        let completedSummary = engine.currentRecord?.summary, completedState = engine.state
        let completedReleases = executor.ble.releases
        engine.stop(); try await waitUntil { !engine.releasing }
        expect(engine.phase == .completed && engine.currentRecord?.outcome == .completed &&
               engine.currentRecord?.summary == completedSummary && engine.state == completedState &&
               executor.ble.releases > completedReleases,
               "Stopping shared capture after completion releases input and preserves the completed result")

        ModelProbe.action = AgentAction(kind: .ask_user, reason: "Offline human handoff")
        engine.start(task: "Needs human", settings: settings)
        try await waitUntil { engine.phase == .needsUser && !engine.releasing }
        expect(engine.currentRecord?.id != submissionID, "Ordinary new tasks retain fresh default identities")
        expect(engine.canResume && engine.pendingAction?.kind == .ask_user, "Human handoff retains task context")
        ModelProbe.action = AgentAction(kind: .finish, reason: "Human issue resolved")
        engine.resume()
        try await waitUntil { engine.phase == .completed && !engine.releasing }
        expect(engine.pendingAction == nil, "Resume discards the old pending action")

        ModelProbe.delay = 1_000_000_000; ModelProbe.action = AgentAction(kind: .tap, x: 0.5, y: 0.5, reason: "Cancelled plan")
        engine.start(task: "Cancel inference", settings: settings)
        try await waitUntil { engine.phase == .observing }
        engine.stop(); try await waitUntil { !engine.releasing }
        expect(engine.phase == .stopped && !engine.canResume, "Explicit stop ends the session")
        expect(executor.actions == [.tap], "Cancelled inference never executes its plan")
        expect(engine.currentRecord?.outcome == .stopped, "Stop is persisted")
        expect(VoiceCommand.parse("助手助手，暂停。") == .pause, "Wake prefix and punctuation support a local pause")
        expect(VoiceCommand.parse("豆包豆包，帮我暂停一下任务") == .pause, "Doubao wake prefix and natural pause wording are recognized")
        expect(VoiceCommand.parse("请帮我暂停当前任务") == .pause, "Polite pause command is recognized")
        expect(VoiceCommand.parse("豆包豆包，我来接管") == .handoff, "Doubao wake prefix supports human handoff")
        expect(VoiceCommand.parse("豆包豆包，帮我继续任务") == .resume, "Doubao wake prefix supports resume")
        expect(VoiceCommand.parse("豆包豆包，停止任务") == .stop, "Doubao wake prefix supports stop")
        expect(VoiceCommand.parse("豆包豆包，我还要补充要求") == .supplement, "Doubao wake prefix supports supplemental instructions")
        expect(VoiceCommand.parse("豆包豆包豆包豆包，先停一下") == .pause, "Repeated wake phrases still allow an exact pause command")
        expect(VoiceCommand.parse("豆包豆包，我来处理") == .handoff, "Natural handoff wording is recognized")
        expect(VoiceCommand.parse("豆包豆包，可以继续了") == .resume, "Natural resume wording is recognized")
        expect(VoiceCommand.parse("豆包豆包，再加一个要求") == .supplement, "Natural supplement wording is recognized")
        expect(VoiceCommand.parse("我有一个补充要求") == nil, "Non-command supplemental prose is preserved as task text")
        expect(VoiceCommand.parse("我来接管") == .handoff, "Handoff is a local command")
        expect(VoiceCommand.parse("继续任务") == .resume, "Resume is a local command")
        expect(VoiceCommand.parse("不要暂停") == nil, "Negated commands are not intercepted")
        expect(VoiceCommand.parse("打开微信然后暂停") == nil, "A task sentence is not a control command")
        expect(VoiceCommand.parse("补充") == .supplement, "Supplement starts the pause-first input flow")
        expect(voiceRoute() == .start, "An idle voice task starts directly")
        expect(voiceRoute(current: true, engineRunning: true) == .busy, "An active task blocks a second spoken task")
        expect(voiceRoute(current: true) == .busy, "A paused current task requires explicit resolution before a new spoken task")
        expect(voiceRoute(pending: 1) == .start, "Legacy pending records do not block or enqueue a new spoken task")
        expect(voiceRoute(pending: 20) == .start, "A full legacy queue remains data rather than routing state")
        expect(voiceRoute(current: true, pending: 1, queueRunning: true, engineRunning: true) == .busy,
               "Current execution cannot be replaced by a spoken task")
        expect(voiceRoute(pending: 1, queueRunning: true) == .busy, "An active legacy queue still blocks concurrent execution")
        expect(voiceRoute(current: true, switching: true) == .busy, "Task switching blocks a new spoken task")
        expect(voiceRoute(current: true, releasing: true) == .busy, "Input release blocks a new spoken task")
        expect(voiceRoute(voicePending: true) == .busy, "Voice preparation blocks duplicate requests")
        expect(voiceRoute(manualBusy: true) == .busy, "Manual input blocks a new spoken task")
        expect(voiceRoute(current: true, calibrating: true) == .busy, "Calibration blocks a new spoken task")
        expect(voiceRoute(engineRunning: true) == .busy, "Active execution blocks a task even before its record becomes visible")
        expect(voiceRoute(queueRunning: true) == .busy, "An inconsistent active queue cannot start a second task")
        var oldTask = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        oldTask.removeValue(forKey: "amendments")
        oldTask.removeValue(forKey: "contextMemory")
        let oldRecord = try JSONDecoder().decode(PhoneTaskRecord.self, from: JSONSerialization.data(withJSONObject: oldTask))
        expect(oldRecord.effectiveGoal == oldRecord.goal, "Older history has no implicit supplemental instructions")
        expect(oldRecord.contextMemory == nil, "Older task records decode without a compacted context checkpoint")

        let actionCount = executor.actions.count
        engine.start(task: "Open a page", settings: settings)
        try await waitUntil { engine.phase == .observing }
        let taskID = engine.currentRecord?.id, step = engine.currentStep
        do { try engine.amendTask("  "); preconditionFailure("Empty supplement was accepted") } catch {}
        expect(engine.running, "An invalid supplement cannot interrupt the task")
        try engine.amendTask("Only inspect; do not send anything")
        expect(engine.phase == .paused && !engine.running, "Supplement cancels the old plan and waits for Continue")
        expect(engine.currentRecord?.id == taskID && engine.currentStep == step, "Supplement preserves task identity and progress")
        expect(engine.currentRecord?.goal == "Open a page", "Original goal remains visible")
        expect(engine.currentRecord?.amendments?.count == 1, "Supplement is recorded once")
        try await waitUntil { !engine.releasing }
        expect(executor.actions.count == actionCount, "The interrupted model response cannot execute")
        let supplemented = engine.currentRecord!
        store.upsert(supplemented)
        expect(TaskHistoryStore(url: path).records.first?.effectiveGoal == supplemented.effectiveGoal, "Supplement survives history reload")
        ModelProbe.delay = 0; ModelProbe.action = AgentAction(kind: .finish, reason: "New requirements verified")
        engine.resume()
        try await waitUntil { engine.phase == .completed && !engine.releasing }
        expect(ModelProbe.goals.last?.contains("Only inspect; do not send anything") == true, "The next model observation receives the new instructions")
        do { try engine.amendTask("Too late"); preconditionFailure("Completed task was amended") } catch {}
        expect(engine.currentRecord?.amendments?.count == 1, "A completed task rejects amendments")

        ModelProbe.delay = 1_000_000_000
        engine.start(task: "Human takeover", settings: settings)
        try await waitUntil { engine.phase == .observing }
        engine.handoff()
        expect(engine.phase == .needsUser && !engine.running && engine.pendingAction == nil, "User takeover discards the pending plan")
        try await waitUntil { !engine.releasing }
        expect(engine.canResume, "Takeover retains a resumable task")
        expect(executor.actions.count == actionCount, "Takeover prevents the old action")
        engine.stop(); try await waitUntil { !engine.releasing }
        expect(!engine.hasCurrentTask, "Stop removes resume eligibility even after handoff")

        // Each production capture-wait span is checked independently. Fixture
        // capture callbacks, model delivery and faults are explicitly staged;
        // cumulative pointer counts never decide which fault to inject.
        var singleStep = settings; singleStep.maxSteps = 1; singleStep.continuousExecution = false
        let reportDirectory=ProcessInfo.processInfo.environment["PHONE_AGENT_TIMING_REPORT_DIR"].map {URL(fileURLWithPath:$0,isDirectory:true)}
        checks += try await WakeTimingChecks.run(settings:settings,reportDirectory:reportDirectory)
        ModelProbe.delay=0;ModelProbe.actionProvider=nil;ModelProbe.onRequest=nil
        ModelProbe.action=AgentAction(kind:.tap,x:0.5,y:0.5,reason:"Fresh-screen tap")
        let selection=UUID()

        // Preview retains capture refresh and works without a connected mouse.
        let previewCapture = CaptureService(), previewExecutor = MouseExecutor()
        previewCapture.frozenFrame = ScreenFrame(captureID: selection)
        previewCapture.onRefresh = { previewCapture.frozenFrame = ScreenFrame(captureID: selection); return true }
        previewExecutor.ble.ready = false
        var previewSettings = singleStep; previewSettings.previewOnly = true
        let previewEngine = AgentEngine(capture: previewCapture, executor: previewExecutor)
        previewEngine.start(task: "Preview a static screen", settings: previewSettings)
        try await waitUntil(timeout: 6) { !previewEngine.running }
        expect(previewEngine.phase == .preview && previewEngine.pendingAction?.kind == .tap,
               "Preview still generates a plan; phase=\(previewEngine.phase.rawValue), error=\(previewEngine.error), action=\(previewEngine.pendingAction?.kind.rawValue ?? "none")")
        expect(previewCapture.refreshes == 2 && previewExecutor.pointerMoves.isEmpty && previewExecutor.actions.isEmpty,
               "Preview refreshes capture without moving or clicking")
        previewCapture.onRefresh = nil

        // Stop while a wake is in flight must not complete its return movement
        // or execute a late model action, even if a fresh frame then arrives.
        ModelProbe.delay = 0
        let cancelledCapture = CaptureService(), cancelledExecutor = MouseExecutor()
        cancelledCapture.frozenFrame = ScreenFrame(captureID: selection)
        cancelledExecutor.movementDelay = 1_000_000_000
        let cancelledEngine = AgentEngine(capture: cancelledCapture, executor: cancelledExecutor)
        cancelledEngine.start(task: "Cancel a pointer wake", settings: singleStep)
        try await waitUntil { cancelledExecutor.pointerMoves.count == 1 }
        cancelledEngine.stop()
        cancelledCapture.frozenFrame = ScreenFrame(captureID: selection)
        try await waitUntil { !cancelledEngine.releasing }
        expect(cancelledEngine.phase == .stopped && cancelledExecutor.actions.isEmpty, "Stop blocks execution after a pointer wake")
        expect(cancelledExecutor.pointerMoves.count == 1 && cancelledExecutor.ble.releases > 0,
               "Stop cancels the remaining wake movement and releases input")

        // Calibration can become invalid after the initial readiness check.
        let invalidCapture = CaptureService(), invalidExecutor = MouseExecutor()
        invalidCapture.frozenFrame = ScreenFrame(captureID: selection)
        let invalidEngine = AgentEngine(capture: invalidCapture, executor: invalidExecutor)
        invalidEngine.start(task: "Do not wake an invalid calibration", settings: singleStep)
        invalidExecutor.calibrationValid = false
        try await waitUntil { !invalidEngine.running && !invalidEngine.releasing }
        expect(invalidEngine.error.contains("calibration invalid") && invalidExecutor.pointerMoves.isEmpty,
               "Invalid calibration fails before any wake movement")

        // The same Back coordinate across different pages must keep working;
        // unchanged pixels and tiny display changes must still stop a loop.
        var repeatedSettings = settings; repeatedSettings.maxSteps = 4; repeatedSettings.continuousExecution = false
        ModelProbe.action = AgentAction(kind: .tap, x: 0.05, y: 0.08, reason: "Back one page")
        for scenario in ["differentPages", "staticPage", "tinyChanges"] {
            let pageCapture = CaptureService(), pageExecutor = MouseExecutor()
            pageCapture.frameProvider = {
                let shade: CGFloat
                if scenario == "differentPages" { shade = 0.1 + CGFloat(pageExecutor.actions.count) * 0.2 }
                else if scenario == "tinyChanges" { shade = 0.5 + CGFloat(pageExecutor.actions.count) * 0.004 }
                else { shade = 0.5 }
                return ScreenFrame(captureID: selection, shade: shade)
            }
            let pageEngine = AgentEngine(capture: pageCapture, executor: pageExecutor)
            pageEngine.start(task: "Return through four pages", settings: repeatedSettings)
            try await waitUntil(timeout: 6) { !pageEngine.running && !pageEngine.releasing }
            if scenario == "differentPages" {
                expect(pageExecutor.actions == [.tap, .tap, .tap, .tap], "The same tap executes across four substantially different pages")
                expect(pageEngine.state.contains("最大步数"), "Progress still respects the configured step limit")
            } else {
                expect(pageExecutor.actions == [.tap, .tap, .tap], "The fourth repeated tap is blocked without substantial progress: \(scenario)")
                expect(pageEngine.error.contains("连续重复同一动作"), "The loop guard reports no substantial screen change: \(scenario)")
                var freshSettings = settings; freshSettings.maxSteps = 1; freshSettings.continuousExecution = false
                pageEngine.start(task: "A new task on the same page", settings: freshSettings)
                try await waitUntil { !pageEngine.running && !pageEngine.releasing }
                expect(pageExecutor.actions.count == 4, "A new session clears the previous repetition baseline: \(scenario)")
            }
            pageCapture.frameProvider = nil
        }

        // Continuous execution crosses both the old 100-step ceiling and the
        // saved finite budget. Each action changes page evidence and target.
        ModelProbe.delay = 0; ModelProbe.calls = 0; ModelProbe.taskContexts = []
        ModelProbe.actionProvider = { call in
            if call > 112 { return AgentAction(kind: .finish, reason: "All 112 pages independently observed") }
            return AgentAction(kind: .tap, x: Double(call % 8 + 1) / 10, y: 0.4,
                               reason: "Inspected page \(call); recorded account user_\(call)")
        }
        var continuous = settings; continuous.continuousExecution = true; continuous.maxSteps = 1
        let longCapture = CaptureService(), longExecutor = MouseExecutor()
        longCapture.frameProvider = {
            ScreenFrame(captureID: selection, shade: longExecutor.actions.count.isMultiple(of: 2) ? 0.2 : 0.8)
        }
        let longEngine = AgentEngine(capture: longCapture, executor: longExecutor)
        longEngine.start(task: "Inspect 112 pages and keep confirmed account references", settings: continuous)
        try await waitUntil(timeout: 12) { longEngine.executionSettled }
        expect(longEngine.phase == .completed && longEngine.currentStep == 113,
               "Continuous execution finishes after more than 110 observations despite maxSteps=1")
        expect(longExecutor.actions.count == 112 && ModelProbe.calls == 113,
               "Every long-task action obtains a new observation without resetting the task")
        expect(longEngine.error.isEmpty && !longEngine.state.contains("最大步数"),
               "Continuous execution does not stop at a hidden automatic step ceiling")
        expect(longEngine.logs.count <= 150 && longEngine.currentRecord?.contextMemory?.prompt.isEmpty == false,
               "Long-task logs stay bounded while older progress enters compact context")
        expect(ModelProbe.taskContexts.dropFirst(20).contains { !$0.isEmpty },
               "The production engine sends compacted progress to later observations")
        let compactedRecord = longEngine.currentRecord!
        let compactedPrompt = compactedRecord.contextMemory!.prompt
        longCapture.frameProvider = nil; ModelProbe.actionProvider = nil

        // Queue files preserve high checkpoints and compact context without
        // restoring execution authority, including an exhausted finite budget.
        let queueURL = directory.appendingPathComponent("long-task-queue.json")
        let queue = TaskQueueStore(url: queueURL)
        var resumableRecord = compactedRecord
        resumableRecord.outcome = .paused; resumableRecord.summary = "Paused for offline recovery check"
        let checkpoint = QueuedPhoneTask(record: resumableRecord, settings: continuous, step: 1000,
                                         started: true, state: .suspended)
        try queue.append(checkpoint)
        var exhaustedRecord = PhoneTaskRecord(title: "Finite task", goal: "Resume after enabling long mode")
        exhaustedRecord.outcome = .paused
        let exhaustedCheckpoint = QueuedPhoneTask(record: exhaustedRecord, settings: singleStep, step: 1,
                                                  started: true, state: .suspended)
        try queue.append(exhaustedCheckpoint)
        let queueReloaded = TaskQueueStore(url: queueURL)
        expect(queueReloaded.error.isEmpty && queueReloaded.items.count == 2,
               "Queue accepts high continuous checkpoints and exhausted finite checkpoints")
        let restoredCheckpoint = queueReloaded.items.first!
        expect(restoredCheckpoint.step == 1000 && restoredCheckpoint.id == compactedRecord.id &&
               restoredCheckpoint.record.contextMemory?.prompt == compactedPrompt,
               "Queue roundtrip preserves task identity, step 1000 and compacted context")
        expect(queueReloaded.items.allSatisfy { $0.state == .suspended },
               "Queue reload always requires manual continuation")
        expect(queueReloaded.items[1].step == 1 && !queueReloaded.items[1].settings.runsContinuously,
               "An exhausted finite checkpoint is retained so its mode can be changed")
        for invalidStep in [-1, Int.max] {
            do {
                try queueReloaded.update(restoredCheckpoint.id) { $0.step = invalidStep }
                preconditionFailure("Queue accepted an invalid step counter")
            } catch {}
            expect(queueReloaded.items.first?.step == 1000,
                   "An invalid checkpoint cannot mutate the last saved queue state")
        }

        ModelProbe.calls = 0; ModelProbe.taskContexts = []
        ModelProbe.action = AgentAction(kind: .finish, reason: "Fresh observation verified after restore")
        let restoredCapture = CaptureService(), restoredExecutor = MouseExecutor()
        let restoredEngine = AgentEngine(capture: restoredCapture, executor: restoredExecutor)
        try restoredEngine.restoreQueued(record: restoredCheckpoint.record, settings: restoredCheckpoint.settings,
                                         step: restoredCheckpoint.step, previouslyStarted: true)
        let restoredPrompt = restoredEngine.currentRecord?.contextMemory?.prompt
        expect(restoredEngine.currentRecord?.id == compactedRecord.id && restoredEngine.currentStep == 1000,
               "Restoring a long checkpoint retains the task ID and completed step count")
        try await waitUntil(timeout: 6) { restoredEngine.executionSettled }
        expect(restoredEngine.phase == .completed && restoredEngine.currentStep == 1001 && ModelProbe.calls == 1,
               "A high-step restore obtains a fresh observation at step 1001")
        expect(restoredExecutor.actions.isEmpty && ModelProbe.taskContexts.first == restoredPrompt &&
               restoredPrompt?.contains("recorded account user_100") == true,
               "Restore reuses compacted progress and never replays the old pending action")

        // The tools-only runner shares the same continuous step policy.
        ModelProbe.calls = 0
        var toolsContinuous = continuous; toolsContinuous.toolsOnly = true; toolsContinuous.systemToolsEnabled = true
        let toolCapture = CaptureService(), toolExecutor = MouseExecutor()
        toolCapture.running = false; toolExecutor.ble.ready = false
        let toolEngine = AgentEngine(capture: toolCapture, executor: toolExecutor)
        toolEngine.systemTool = { _, _ in "Offline receipt" }
        ModelProbe.action = AgentAction(kind: .finish, text: finalReport, reason: "简短完成说明")
        try toolEngine.restoreQueued(record: restoredCheckpoint.record, settings: toolsContinuous,
                                    step: 1000, previouslyStarted: true)
        try await waitUntil { toolEngine.executionSettled }
        expect(toolEngine.phase == .completed && toolEngine.currentStep == 1001 && ModelProbe.calls == 1,
               "Tools-only continuous mode also resumes beyond step 100 without capture or BLE")
        expect(toolEngine.currentRecord?.summary == finalReport && toolEngine.state == finalReport,
               "Tools-only completion also persists the full report")

        // Finite mode pauses at its chosen budget, then the same task can
        // continue after explicitly changing to long-task mode.
        ModelProbe.calls = 0
        ModelProbe.action = AgentAction(kind: .tap, x: 0.3, y: 0.6, reason: "One finite action")
        let finiteCapture = CaptureService(), finiteExecutor = MouseExecutor()
        let finiteEngine = AgentEngine(capture: finiteCapture, executor: finiteExecutor)
        finiteEngine.start(task: "Continue the same finite task in long mode", settings: singleStep)
        try await waitUntil { finiteEngine.executionSettled }
        let finiteID = finiteEngine.currentRecord?.id
        expect(finiteEngine.phase == .paused && finiteEngine.canResume && finiteEngine.currentStep == 1,
               "Finite mode pauses with a resumable checkpoint at the exact configured limit")
        finiteEngine.resume()
        expect(!finiteEngine.running && ModelProbe.calls == 1,
               "An exhausted finite budget cannot dispatch another observation")
        ModelProbe.action = AgentAction(kind: .finish, reason: "Long mode continuation verified")
        finiteEngine.resume(settings: continuous)
        try await waitUntil(timeout: 6) { finiteEngine.executionSettled }
        expect(finiteEngine.phase == .completed && finiteEngine.currentStep == 2 &&
               finiteEngine.currentRecord?.id == finiteID && finiteExecutor.actions.count == 1,
               "Enabling long mode resumes the original task past its former finite limit")

        // Long mode retains local controls and completes release before a
        // resumed task can dispatch another action.
        ModelProbe.action = AgentAction(kind: .tap, x: 0.7, y: 0.2, reason: "Cancellable long-task action")
        let controlledCapture = CaptureService(), controlledExecutor = MouseExecutor()
        controlledExecutor.actionDelay = 1_000_000_000
        let controlledEngine = AgentEngine(capture: controlledCapture, executor: controlledExecutor)
        controlledEngine.start(task: "Pause and stop a continuous task", settings: continuous)
        try await waitUntil { controlledEngine.phase == .acting }
        controlledEngine.pause()
        expect(controlledEngine.phase == .paused && controlledEngine.releasing,
               "A continuous task pauses immediately and blocks resume during release")
        try await waitUntil { controlledEngine.executionSettled }
        expect(controlledExecutor.ble.releases > 0 && controlledEngine.canResume,
               "Pause releases continuous-task input and preserves continuation")
        let beforeStopReleases = controlledExecutor.ble.releases
        controlledEngine.resume()
        try await waitUntil(timeout: 6) { controlledEngine.phase == .acting }
        controlledEngine.stop()
        try await waitUntil { controlledEngine.executionSettled }
        expect(controlledEngine.phase == .stopped && !controlledEngine.canResume &&
               controlledExecutor.ble.releases > beforeStopReleases,
               "Stop cancels a resumed continuous task and releases its input")
        expect(controlledExecutor.actions.count == 2,
               "Cancelled long-task actions are never retried automatically")
        ModelProbe.actionProvider = nil
        checks += try await TaskRecoveryChecks.run(directory: directory, settings: settings)
        print("\(checks) product-state checks passed. No network, phone or BLE actions.")
    }
}
