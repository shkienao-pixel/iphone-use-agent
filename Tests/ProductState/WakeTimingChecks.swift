import Foundation

/// Exercises the unchanged production AgentEngine against explicit offline
/// capture callbacks. Reading a frame never creates or refreshes one here.
@MainActor enum WakeTimingChecks {
    private enum Fault: String, Codable {
        case none, selectionChanged, pixelsChanged, stopped, silent, noFrame
        case staleWithoutIdle, staleWithIdle, cancelWake, gatedModel, cancelModel
    }
    private struct Scenario {
        var name: String
        var earlyStartup = false
        var fault: Fault = .none
        var requiresDeadline = false
    }
    private struct Movement: Codable {
        var ordinal: Int
        var spanID: UUID?
        var stage: String
        var observedAt: Date
        var x: Int
        var y: Int
        var buttons: UInt8
    }
    private struct Event: Codable {
        var kind: String
        var at: Date
        var spanID: UUID?
        var stage: String
        var capturedAt: Date?
        var confirmedAt: Date?
        var captureID: UUID?
        var after: Date?
        var detail: String
    }
    private struct WaitReport: Codable {
        var span: RunTimingSpan
        var stage: String
        var movements: [Movement]
    }
    private struct Assertion: Codable {
        var passed: Bool
        var description: String
    }
    private struct Report: Codable {
        var scenario: String
        var fault: Fault
        var earlyStartup: Bool
        var stressMode: Bool
        var phase: String
        var state: String
        var error: String
        var modelCalls: Int
        var actions: [String]
        var refreshes: Int
        var releases: Int
        var elapsedSeconds: Double
        var captureWaits: [WaitReport]
        var movements: [Movement]
        var events: [Event]
        var assertions: [Assertion]
        var harnessError: String?
        var note = "Offline fixture callbacks and production capture spans; no device, BLE, network or task acceptance. Date values are Unix milliseconds. Original pixel timestamps never change on idle confirmation."
    }
    private struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Intentionally a synchronous, controlled consumer stall. It proves the
    /// real 1.5-second guard without changing production time or capture code.
    /// The test records the callback BEFORE this delay; its timestamp is not
    /// retimed when the consumer resumes.
    private static func delayConsumer() { Thread.sleep(forTimeInterval: 1.7) }

    @MainActor private final class Fixture {
        let scenario: Scenario
        let capture = CaptureService()
        let executor = MouseExecutor()
        let gate = FrameReadinessGate()
        let selection = UUID()
        var engine: AgentEngine!
        var events: [Event] = []
        var movements: [Movement] = []
        var stages: [UUID: String] = [:]
        var startupDelivered = false
        var faultInjected = false
        var delayed = false
        var modelContinuation: CheckedContinuation<Void, Error>?
        var modelSuspended = false
        var heldModelHadNoAction = false
        var lateResumeDidNotReplay = false
        var idlePreservedPixels = true

        init(_ scenario: Scenario) {
            self.scenario = scenario
            capture.frozenFrame = ScreenFrame(captureID: selection)
            engine = AgentEngine(capture: capture, executor: executor)
            executor.onMove = { [weak self] in self?.moveCompleted() }
            capture.waitHandler = { [weak self] after, timeout in
                guard let self else { throw CancellationError() }
                return try await self.wait(after: after, timeout: timeout)
            }
            if scenario.fault == .cancelWake { executor.movementDelay = 1_000_000_000 }
        }
        var activeSpan: RunTimingSpan? {
            engine.runMetrics?.snapshot.spans.last { $0.category == .capture && $0.end == nil }
        }
        func stage(_ span: RunTimingSpan?) -> String {
            guard let span else { return "outsideCaptureWait" }
            if let existing = stages[span.id] { return existing }
            // Faults bind to the current production span and model phase, never
            // to the lifetime movement count. Early acquisition can use 0 moves.
            let value = ModelProbe.calls == 0 ? "startup" : "modelReturnValidation"
            stages[span.id] = value
            return value
        }
        func event(_ kind: String, detail: String = "", after: Date? = nil) {
            let span = activeSpan, frame = capture.frame
            events.append(.init(kind: kind, at: Date(), spanID: span?.id, stage: stage(span),
                capturedAt: frame?.capturedAt, confirmedAt: frame?.confirmedAt,
                captureID: frame?.captureID, after: after, detail: detail))
        }
        func recordNewMoves() {
            let span = activeSpan, phase = stage(span)
            for index in movements.count..<executor.pointerMoves.count {
                let move = executor.pointerMoves[index]
                movements.append(.init(ordinal: index + 1, spanID: span?.id, stage: phase,
                    observedAt: Date(), x: move.x, y: move.y, buttons: move.buttons))
            }
        }
        func moves(in span: RunTimingSpan?) -> Int {
            guard let span else { return 0 }
            return movements.filter { $0.spanID == span.id }.count
        }
        func publishIdle(_ reason: String) {
            guard capture.running, let previous = capture.frozenFrame else { return }
            // This is a source callback with real callback time and the exact
            // retained pixel object. Neither the frame getter nor a timer
            // fabricates capturedAt/confirmedAt.
            capture.frozenFrame = previous.confirmed(at: Date())
            if let confirmed = capture.frozenFrame {
                idlePreservedPixels = idlePreservedPixels && confirmed.capturedAt == previous.capturedAt &&
                    confirmed.captureID == previous.captureID && confirmed.image.cgImage === previous.image.cgImage
            } else { idlePreservedPixels = false }
            gate.update(confirmedAt: capture.frame?.confirmedAt, available: true)
            event("idleCallback", detail: reason)
        }
        func moveCompleted() {
            recordNewMoves()
            let span = activeSpan, phase = stage(span)
            event("movementReturned", detail: "The fake input returned; this event alone supplies no capture evidence")
            if phase == "modelReturnValidation", !faultInjected {
                switch scenario.fault {
                case .selectionChanged:
                    faultInjected = true
                    capture.frozenFrame = ScreenFrame(captureID: UUID())
                    gate.update(confirmedAt: capture.frame?.confirmedAt, available: true)
                    event("changedSelectionCallback")
                    return
                case .pixelsChanged:
                    faultInjected = true
                    capture.frozenFrame = ScreenFrame(captureID: selection, shade: 0)
                    gate.update(confirmedAt: capture.frame?.confirmedAt, available: true)
                    event("changedPixelsCallback")
                    return
                case .stopped:
                    faultInjected = true; capture.running = false
                    gate.update(confirmedAt: nil, available: false)
                    event("captureStoppedCallback")
                    return
                case .silent:
                    faultInjected = true
                    event("sourceSilent", detail: "No further complete or idle callback will be delivered in this span")
                default: break
                }
            }
            if phase == "modelReturnValidation", scenario.fault == .silent { return }
            if phase == "startup", [.staleWithoutIdle, .staleWithIdle].contains(scenario.fault) {
                publishIdle("A real callback arrives during the controlled wake")
                if moves(in: span) == 2, !delayed {
                    delayed = true
                    event("consumerDelayBegan", detail: "Explicit synchronous 1.7-second test stall after callback publication")
                    WakeTimingChecks.delayConsumer()
                    event("consumerDelayEnded", detail: "No timestamp was changed while the consumer was stalled")
                }
            }
            // Normal callbacks are delivered in wait(), which represents the
            // independent source notification after the movement pair.
        }
        func wait(after: Date, timeout: TimeInterval) async throws -> Bool {
            recordNewMoves()
            let span = activeSpan, phase = stage(span), moveCount = moves(in: span)
            event("waitEntered", after: after)
            if capture.running {
                if scenario.fault == .noFrame {
                    // Deliberately no callback; frameProvider keeps nil without
                    // invoking the default fake's synthetic frame getter.
                } else if phase == "startup", scenario.earlyStartup, !startupDelivered {
                    startupDelivered = true; publishIdle("Explicit startup callback before the 0.3-second wake threshold")
                } else if phase == "startup", scenario.fault == .staleWithoutIdle, delayed {
                    // The once-delivered confirmation really is >1.5 s old.
                } else if phase == "modelReturnValidation", scenario.fault == .silent {
                    // No move can mint evidence. The real gate must time out.
                } else if moveCount > 0 || span == nil {
                    publishIdle("Explicit independent idle callback delivered to the real FrameReadinessGate")
                }
            }
            gate.update(confirmedAt: capture.frame?.confirmedAt, available: capture.running)
            do {
                let result = try await gate.wait(after: after, timeout: timeout)
                event("waitReturned", detail: "ready=\(result)", after: after)
                return result
            } catch {
                event("waitThrew", detail: String(describing: error), after: after)
                throw error
            }
        }
        func modelRequest() async throws {
            recordNewMoves(); event("modelRequested")
            guard [.gatedModel, .cancelModel].contains(scenario.fault) else { return }
            try await withCheckedThrowingContinuation { continuation in
                modelSuspended = true; modelContinuation = continuation
                event("modelHeld", detail: "A continuation, not a fixed inference sleep, controls completion")
            }
            event("modelReleased")
        }
        func releaseModel() {
            let continuation = modelContinuation; modelContinuation = nil
            continuation?.resume(returning: ())
        }
        func cleanup() {
            releaseModel(); executor.onMove = nil; capture.waitHandler = nil
        }
        func report(stressMode: Bool, began: Date, harnessError: String?) -> Report {
            recordNewMoves()
            let attributed = (engine.runMetrics?.snapshot.spans ?? []).filter { $0.category == .capture }.map { span in
                WaitReport(span: span, stage: stages[span.id] ?? "unclassified",
                    movements: movements.filter { $0.spanID == span.id })
            }
            return .init(scenario: scenario.name, fault: scenario.fault, earlyStartup: scenario.earlyStartup,
                stressMode: stressMode, phase: engine.phase.rawValue, state: engine.state, error: engine.error,
                modelCalls: ModelProbe.calls, actions: executor.actions.map(\.rawValue), refreshes: capture.refreshes,
                releases: executor.ble.releases, elapsedSeconds: Date().timeIntervalSince(began),
                captureWaits: attributed, movements: movements, events: events, assertions: [], harnessError: harnessError)
        }
    }

    static func run(settings: AgentSettings, reportDirectory: URL? = nil, stressMode: Bool = false) async throws -> Int {
        let directory = reportDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("WakeTiming-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let saved = (ModelProbe.calls, ModelProbe.goals, ModelProbe.taskContexts, ModelProbe.delay,
                     ModelProbe.action, ModelProbe.actionProvider, ModelProbe.onRequest)
        defer {
            (ModelProbe.calls, ModelProbe.goals, ModelProbe.taskContexts, ModelProbe.delay,
             ModelProbe.action, ModelProbe.actionProvider, ModelProbe.onRequest) = saved
        }
        var single = settings
        single.startDelay = 0; single.stepInterval = 0.4; single.maxSteps = 1
        single.continuousExecution = false; single.confirmEachStep = false; single.previewOnly = false
        var scenarios: [Scenario] = [
            .init(name: "normal-two-waits"),
            .init(name: "startup-no-wake", earlyStartup: true),
            .init(name: "early-start-selection-changed", earlyStartup: true, fault: .selectionChanged),
            .init(name: "early-start-pixels-changed", earlyStartup: true, fault: .pixelsChanged),
            .init(name: "early-start-source-stopped", earlyStartup: true, fault: .stopped),
            .init(name: "gated-model-return", earlyStartup: true, fault: .gatedModel),
            .init(name: "stop-during-wake", fault: .cancelWake),
            .init(name: "stop-during-gated-model", earlyStartup: true, fault: .cancelModel),
            .init(name: "stale-callback-then-real-idle", fault: .staleWithIdle)
        ]
        if !stressMode {
            scenarios += [
                .init(name: "early-start-source-silent", earlyStartup: true, fault: .silent, requiresDeadline: true),
                .init(name: "no-frame-no-wake", fault: .noFrame, requiresDeadline: true),
                .init(name: "stale-callback-without-idle", fault: .staleWithoutIdle, requiresDeadline: true)
            ]
        }
        var reports: [Report] = [], checks = 0
        for scenario in scenarios {
            ModelProbe.calls = 0; ModelProbe.delay = 0; ModelProbe.actionProvider = nil
            ModelProbe.action = AgentAction(kind: .tap, x: 0.5, y: 0.5, reason: "Explicit new capture evidence is required")
            let fixture = Fixture(scenario), began = Date()
            ModelProbe.onRequest = { [weak fixture] in try await fixture?.modelRequest() }
            var harnessError: String?
            fixture.engine.start(task: "Offline phase-bound pointer wake check", settings: single)
            if scenario.fault == .noFrame { fixture.capture.frameProvider = { nil } }
            do {
                if [.gatedModel, .cancelModel].contains(scenario.fault) {
                    try await until(timeout: 8) { fixture.modelContinuation != nil || fixture.engine.executionSettled }
                    fixture.heldModelHadNoAction = fixture.modelContinuation != nil && fixture.executor.actions.isEmpty && fixture.engine.running
                    if scenario.fault == .cancelModel { fixture.event("userStopped"); fixture.engine.stop() }
                    fixture.releaseModel()
                } else if scenario.fault == .cancelWake {
                    try await until(timeout: 8) { !fixture.executor.pointerMoves.isEmpty || fixture.engine.executionSettled }
                    fixture.recordNewMoves(); fixture.event("userStopped"); fixture.engine.stop()
                }
                try await until(timeout: scenario.requiresDeadline ? 10 : 9) { fixture.engine.executionSettled }
                if [.cancelModel, .cancelWake].contains(scenario.fault) {
                    let before = (fixture.executor.actions.count, ModelProbe.calls, fixture.executor.pointerMoves.count)
                    fixture.engine.resume()
                    await Task.yield()
                    fixture.lateResumeDidNotReplay = fixture.engine.executionSettled && !fixture.engine.canResume &&
                        before.0 == fixture.executor.actions.count && before.1 == ModelProbe.calls && before.2 == fixture.executor.pointerMoves.count
                    fixture.event("resumeAfterStopRejected", detail: "No saved execution authority, input or model request was restored")
                }
            } catch {
                harnessError = error.localizedDescription
                fixture.releaseModel(); fixture.engine.stop()
                try? await until(timeout: 3) { fixture.engine.executionSettled }
            }
            var report = fixture.report(stressMode: stressMode, began: began, harnessError: harnessError)
            func check(_ condition: Bool, _ description: String) {
                report.assertions.append(.init(passed: condition, description: description)); checks += 1
            }
            check(harnessError == nil, "The fixture reached an engine terminal state without a harness deadline failure")
            check(report.refreshes == 0, "Pointer wake never restarts capture")
            check(report.movements.count == fixture.executor.pointerMoves.count && report.movements.allSatisfy { $0.spanID != nil }, "Every actual move is attributed to one production capture span UUID")
            check(report.captureWaits.allSatisfy { $0.movements.count <= 2 }, "Each individual production capture wait sends at most one wake pair")
            check(report.captureWaits.allSatisfy { wait in
                wait.movements.enumerated().allSatisfy { index, move in move.x == (index == 0 ? 3 : -3) && move.y == 0 && move.buttons == 0 }
            }, "Every per-wait movement is the exact +3 then -3 zero-button sequence")
            check(report.captureWaits.allSatisfy { $0.span.end != nil && $0.span.outcome != nil }, "All real capture spans have terminal timing outcomes")
            check(report.events.allSatisfy { event in
                guard let pixels = event.capturedAt, let confirmed = event.confirmedAt else { return true }
                return pixels <= confirmed && confirmed <= event.at
            }, "Reported pixel and confirmation timestamps retain their actual order")
            check(fixture.idlePreservedPixels, "Every explicit idle callback retains the exact pixel image object, capturedAt and capture selection")
            let startup = report.captureWaits.filter { $0.stage == "startup" }
            let validation = report.captureWaits.filter { $0.stage == "modelReturnValidation" }
            check(startup.count == 1, "Exactly one startup acquisition span is identified independently of the movement count")
            if scenario.earlyStartup {
                check(startup.first?.movements.isEmpty == true, "An explicit callback before recovery obtains the initial frame with zero wake moves")
            }
            switch scenario.fault {
            case .none, .gatedModel, .staleWithIdle:
                check(report.phase == "paused" && report.error.isEmpty && report.actions == ["tap"] && report.modelCalls == 1, "Only the valid current-selection path dispatches one tap and reaches the finite step limit")
                check(validation.count == 1 && validation.first?.movements.count == 2, "The post-model wait independently performs one complete pair")
                check(report.captureWaits.allSatisfy { $0.span.outcome == .completed }, "All capture waits complete from actual source callbacks")
                if !scenario.earlyStartup { check(startup.first?.movements.count == 2, "A static initial source performs one complete startup pair") }
                if scenario.fault == .gatedModel { check(fixture.modelSuspended && fixture.heldModelHadNoAction, "Inference is actually continuation-gated with no action while held") }
                if scenario.fault == .staleWithIdle {
                    let end = report.events.first { $0.kind == "consumerDelayEnded" }
                    check(fixture.delayed && end.map { ended in report.events.contains {
                        $0.kind == "idleCallback" && $0.stage == "startup" && $0.at > ended.at &&
                            ($0.confirmedAt.map { $0 > ended.at } ?? false) && $0.capturedAt == ended.capturedAt
                    } } == true, "The stale callback recovers only after a later independently timestamped idle callback retaining the same pixels")
                }
            case .selectionChanged, .pixelsChanged:
                check(fixture.faultInjected && report.modelCalls == 1 && report.actions.isEmpty && report.phase == "paused", "A fault bound to the post-model phase discards the old action even when initial acquisition used no wake")
                check(validation.count == 1 && validation.first?.movements.count == (scenario.fault == .selectionChanged ? 1 : 2), "Selection replacement skips the return move; changed pixels retain a complete zero-button pair")
                check(fixture.engine.logs.contains { $0.title == (scenario.fault == .selectionChanged ? "共享或画面尺寸已改变" : "画面已改变") }, "The actual production identity or pixel guard, not a fixture rejection, discards the action")
            case .stopped:
                check(fixture.faultInjected && report.actions.isEmpty && report.modelCalls == 1 && report.phase == "failed" && report.error.contains("共享已停止"), "A stopped capture fails safely after the model without dispatch")
                check(validation.count == 1 && validation.first?.movements.count == 1 && validation.first?.span.outcome == .failed, "Capture stop prevents the second movement in that specific wait")
            case .silent, .noFrame, .staleWithoutIdle:
                check(report.phase == "failed" && report.error.contains("6 秒") && report.actions.isEmpty, "Absent usable source evidence fails at the unchanged production deadline without input")
                let failed = report.captureWaits.filter { $0.span.outcome == .failed }
                check(failed.count == 1 && failed[0].span.end! - failed[0].span.start >= 5.9, "The actual failed capture span does not time out before the production six-second deadline; scheduler delay is not claimed to have a strict upper bound")
                if scenario.fault == .silent {
                    check(fixture.faultInjected && report.modelCalls == 1 && validation.first?.movements.count == 2, "A silent source fault activates in validation even though startup had zero moves")
                } else if scenario.fault == .noFrame {
                    check(report.modelCalls == 0 && report.movements.isEmpty, "No frame means no calibrated pointer wake or model request")
                } else {
                    check(fixture.delayed && report.modelCalls == 0 && startup.first?.movements.count == 2, "The once-delivered frame expires during the controlled 1.7-second stall and is never retimed")
                    if let end = report.events.first(where: { $0.kind == "consumerDelayEnded" }) {
                        check(!report.events.contains { $0.kind == "idleCallback" && $0.at > end.at }, "No confirmation callback is delivered after the deliberate stale-consumer stall")
                    } else { check(false, "The stale-consumer experiment recorded its delay boundary") }
                }
            case .cancelWake, .cancelModel:
                check(report.phase == "stopped" && report.actions.isEmpty && report.releases > 0 && fixture.lateResumeDidNotReplay, "Stop cancels old authority, releases input and cannot replay a late result or revive the stopped task")
                if scenario.fault == .cancelWake {
                    check(report.movements.count == 1 && report.movements.first?.x == 3 && report.modelCalls == 0 && startup.first?.span.outcome == .cancelled, "Stopping an in-flight initial wake cancels the inverse move and the capture span")
                } else {
                    check(fixture.heldModelHadNoAction && report.modelCalls == 1 && report.movements.isEmpty, "Stopping a held model suppresses its returned tap without beginning validation or waking")
                }
            }
            if [.staleWithIdle, .staleWithoutIdle].contains(scenario.fault) {
                let start = report.events.first { $0.kind == "consumerDelayBegan" }
                let end = report.events.first { $0.kind == "consumerDelayEnded" }
                check(start.flatMap { started in end.map { ended in
                    ended.at.timeIntervalSince(started.at) >= 1.65 && started.confirmedAt == ended.confirmedAt &&
                        ended.confirmedAt.map { ended.at.timeIntervalSince($0) >= 1.5 } == true
                } } == true, "The actual consumer stall exceeds the unchanged freshness window and does not renew confirmation time")
            }
            fixture.cleanup(); reports.append(report)
            try write(report, to: directory.appendingPathComponent(scenario.name + ".json"))
            print("WakeTiming \(scenario.name): moves=\(report.movements.count), perWait=\(report.captureWaits.map { $0.movements.count }), calls=\(report.modelCalls), actions=\(report.actions), phase=\(report.phase), error=\(report.error)")
        }
        try write(reports, to: directory.appendingPathComponent("all-scenarios.json"))
        let failures = reports.flatMap { report in report.assertions.filter { !$0.passed }.map { report.scenario + ": " + $0.description } }
        // Persist the complete evidence (including actual counts and failed
        // assertions) before raising anything that can terminate a caller.
        guard failures.isEmpty else {
            throw Failure(message: "Wake timing failed after writing \(directory.path):\n" + failures.joined(separator: "\n") + "\n" + (try json(reports)))
        }
        print("WakeTiming: \(checks) checks passed across \(reports.count) scenarios; report=\(directory.path); offline fixtures only")
        return checks
    }
    private static func until(timeout: TimeInterval, _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw Failure(message: "Wake fixture state deadline exceeded") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    private static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .millisecondsSince1970
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try Data(json(value).utf8).write(to: url, options: .atomic)
    }
}
