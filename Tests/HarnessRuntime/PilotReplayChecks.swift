import Foundation

final class PilotDecisionBox {
    private let lock = NSLock()
    private var values: [TaskCheckpointDecision] = []
    func append(_ value: TaskCheckpointDecision) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func snapshot() -> [TaskCheckpointDecision] { lock.lock(); defer { lock.unlock() }; return values }
}

@MainActor final class WrongFrameHarness: PhoneHarnessDriving {
    let runtime: PhoneHarnessRuntime
    init(_ runtime: PhoneHarnessRuntime) { self.runtime = runtime }
    var metrics: RunMetricsRecorder? { get { runtime.metrics } set { runtime.metrics = newValue } }
    var hasPendingReview: Bool { runtime.hasPendingReview }
    var taskScopeID: UUID? { get { runtime.taskScopeID } set { runtime.taskScopeID = newValue } }
    var checkpointRuntimeGeneration: UUID? { runtime.checkpointRuntimeGeneration }
    func reset() { runtime.reset() }
    func context(for frame: ScreenFrame) async throws -> String { try await runtime.context(for: frame) }
    func didExecute(_ action: AgentAction, frame: ScreenFrame) async { await runtime.didExecute(action, frame: frame) }
    func execute(_ request: PhoneHarnessRequest, frame: ScreenFrame, mappedHome: Bool,
                 nextFrame: @escaping @MainActor (Date) async throws -> ScreenFrame) async throws -> PhoneHarnessReceipt {
        var result = try await runtime.execute(request, frame: frame, mappedHome: mappedHome, nextFrame: nextFrame)
        if let original = result.checkpointFrame {
            result.checkpointFrame = ScreenFrame(capturedAt: original.capturedAt.addingTimeInterval(-20), captureID: original.captureID)
        }
        return result
    }
}

// Actual Engine and Runtime, with synthetic model, capture, OCR and input.
// Each replay starts from the same home and ends after the same search result.
@MainActor enum PilotReplayChecks {
    struct Result {
        let actions: [AgentAction.Kind]
        let modelCalls: Int
        let ocrCalls: Int
        let captureRefreshes: Int
        let outcome: TaskOutcome?
        let step: Int
        let logTitles: [String]
        let decisions: [TaskCheckpointDecision]
        let elapsed: TimeInterval
    }
    enum SinkFailure: Error { case unavailable }

    static func run(directory: URL, home: [PhoneUIElement], search: [PhoneUIElement]) async throws -> Int {
        let taskID = UUID(), goal = "Open the system search page and stay there"
        func replay(_ name: String, pilot: Bool, failingSink: Bool = false, wrongTask: Bool = false,
                    wrongGoal: Bool = false, reconnect: Bool = false, wrongFrame: Bool = false,
                    interrupt: String? = nil, rejectedRestore: Bool = false) async throws -> Result {
            let tape = OCRFixtures(), executor = MouseExecutor(), capture = CaptureService()
            var visible = home
            capture.frameProvider = { tape.frame(visible) }
            executor.onAction = { action in if action.kind == .tap { visible = search } }
            let runtime = PhoneHarnessRuntime(executor: executor,
                memoryURL: directory.appendingPathComponent("replay-" + name + ".json"), recognize: tape.recognize)
            let engine = AgentEngine(capture: capture, executor: executor)
            if wrongFrame { engine.phoneHarness = WrongFrameHarness(runtime) }
            else { engine.phoneHarness = runtime }
            let decisionBox = PilotDecisionBox()
            if pilot {
                engine.configureCheckpointPilot(taskID: wrongTask ? UUID() : taskID, goal: wrongGoal ? "Another goal" : goal) { decision in
                    decisionBox.append(decision)
                    if failingSink { try Data("diagnostic".utf8).write(to: URL(fileURLWithPath: "/dev/null/unwritable")) }
                }
            }
            ModelProbe.calls = 0; ModelProbe.delay = 0
            ModelProbe.onRequest = {
                if reconnect && ModelProbe.calls == 2 { executor.ble.pointerConnectionGeneration = UUID() }
                if ModelProbe.calls == 2 {
                    if rejectedRestore, let record = engine.currentRecord, let settings = engine.currentSettings {
                        do { try engine.restoreQueued(record: record, settings: settings, step: 0, previouslyStarted: false); preconditionFailure("restore while running accepted") } catch {}
                    }
                    switch interrupt {
                    case "pause": engine.pause()
                    case "stop": engine.stop()
                    case "amend": try engine.amendTask("Change the request")
                    default: break
                    }
                }
            }
            ModelProbe.actionProvider = { index in
                index == 1 ? AgentAction(kind: .phone_tool, text: #"{"operation":"open_search"}"#, reason: "Open search")
                           : AgentAction(kind: .finish, reason: "Search observed")
            }
            var settings = AgentSettings(); settings.startDelay = 0; settings.stepInterval = 1
            settings.maxSteps = 2; settings.continuousExecution = false
            PrivacyConsent.grant(settings)
            let start = Date()
            engine.start(task: goal, settings: settings, taskID: taskID)
            let deadline = Date().addingTimeInterval(10)
            while !engine.executionSettled && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            precondition(engine.executionSettled, "Offline replay timed out")
            if pilot && !wrongTask && !wrongGoal && interrupt == nil {
                let diagnosticDeadline = Date().addingTimeInterval(2)
                while decisionBox.snapshot().isEmpty && Date() < diagnosticDeadline { try await Task.sleep(nanoseconds: 5_000_000) }
            }
            let result = Result(actions: executor.actions, modelCalls: ModelProbe.calls, ocrCalls: tape.recognitions, captureRefreshes: capture.refreshes,
                outcome: engine.currentRecord?.outcome, step: engine.currentStep,
                logTitles: engine.logs.map(\.title), decisions: decisionBox.snapshot(), elapsed: Date().timeIntervalSince(start))
            ModelProbe.actionProvider = nil; ModelProbe.onRequest = nil; PrivacyConsent.revoke()
            return result
        }
        let off = try await replay("off", pilot: false)
        let on = try await replay("on", pilot: true)
        let broken = try await replay("sink-failure", pilot: true, failingSink: true)
        let wrongTask = try await replay("wrong-task", pilot: true, wrongTask: true)
        let wrongGoal = try await replay("wrong-goal", pilot: true, wrongGoal: true)
        let reconnect = try await replay("reconnect", pilot: true, reconnect: true)
        let wrongFrame = try await replay("wrong-frame", pilot: true, wrongFrame: true)
        let rejected = try await replay("rejected-restore", pilot: true, rejectedRestore: true)
        func sameBehavior(_ a: Result, _ b: Result) -> Bool {
            a.actions == b.actions && a.modelCalls == b.modelCalls && a.ocrCalls == b.ocrCalls && a.captureRefreshes == b.captureRefreshes &&
            a.outcome == b.outcome && a.step == b.step && a.logTitles == b.logTitles
        }
        for event in ["pause", "stop", "amend"] {
            let baseline = try await replay(event + "-off", pilot: false, interrupt: event)
            let trial = try await replay(event + "-on", pilot: true, interrupt: event)
            precondition(sameBehavior(baseline, trial) && trial.decisions.isEmpty,
                "Interrupted pilot must preserve behavior and suppress old diagnostics")
        }
        precondition(off.actions == [.tap] && off.modelCalls == 2 && off.outcome == .completed,
            "Production replay must actually dispatch the search and reach the original completion")
        precondition(sameBehavior(off, on), "Pilot must preserve actions, model/OCR calls, task outcome, steps and log titles")
        precondition(sameBehavior(off, broken), "A throwing diagnostic sink cannot affect original behavior")
        precondition(off.decisions.isEmpty && on.decisions.count == 1 && broken.decisions.count == 1,
            "Only bound pilot tasks send a diagnostic, including the sink-failure injection")
        precondition(on.decisions[0].verdict == .unknown && broken.decisions[0].verdict == .unknown,
            "A generic search scene cannot be treated as verified system search")
        precondition(wrongTask.decisions.isEmpty && wrongGoal.decisions.isEmpty && sameBehavior(off, wrongTask) && sameBehavior(off, wrongGoal),
            "A pilot bound to a different task or goal cannot attach to an ordinary task")
        precondition(rejected.decisions.count == 1 && sameBehavior(off, rejected), "A rejected queue restore cannot disable the running pilot")
        precondition(reconnect.decisions.count == 1 && reconnect.decisions[0].verdict == .unknown &&
                     reconnect.decisions[0].reason == "binding_changed", "Reconnection invalidates old facts")
        precondition(wrongFrame.decisions.count == 1 && wrongFrame.decisions[0].verdict == .unknown && sameBehavior(off, wrongFrame),
            "A fact accompanied by different pixels cannot pass or change original behavior")
        print("Pilot replay: actions=\(off.actions.count), model=\(off.modelCalls), OCR=\(off.ocrCalls), capture-refresh=\(off.captureRefreshes), outcome=completed; off/on/failing sink behavior identical. Wall seconds off/on/throw=\(off.elapsed)/\(on.elapsed)/\(broken.elapsed) (single synthetic samples, not a benchmark).")
        return 12
    }
}
