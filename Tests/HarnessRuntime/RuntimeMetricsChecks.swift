import Foundation

private enum RuntimeMetricsSyntheticError: Error { case recognition }

@MainActor enum HarnessRuntimeMetricsChecks {
    private enum Mode: String, CaseIterable {
        case successAndHit, emptyAndHit, nonCandidateAndHit
        case roiThrow, roiCancellation, roiReturnThenCancel, roiReturnThenAccessoryChange
        case fullThrow, fullCancellation, fullReturnThenCancel, fullReturnThenAccessoryChange
        case staleCacheHit, cancelledCacheHit
        var readsCache: Bool { [.successAndHit, .emptyAndHit, .nonCandidateAndHit, .staleCacheHit, .cancelledCacheHit].contains(self) }
        var hasROI: Bool { ![.nonCandidateAndHit, .fullThrow, .fullCancellation, .fullReturnThenCancel, .fullReturnThenAccessoryChange].contains(self) }
    }
    private struct Result {
        var fullCalls: Int
        var roiCalls: Int
        var snapshots: [PhoneUISnapshot]
        var error: String
        var clock: Double
        var metrics: AgentRunMetrics?
        var initialNotes: [String]
        var inputs: Int
    }
    private static func element(_ id: String, _ label: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> PhoneUIElement {
        .init(id: id, label: label, rect: .init(x: x, y: y, width: width, height: height), source: "ocr")
    }
    private static let candidate = [element("account", "Weixin ID: filehelper", 0.214, 0.170, 0.347, 0.016),
        element("about1", "Transfer text, images, audio and video files", 0.217, 0.263, 0.738, 0.020),
        element("about2", "between your device and your PC", 0.217, 0.283, 0.581, 0.020),
        element("messages", "• Messages", 0.378, 0.347, 0.247, 0.021)]
    private static let title = element("fixture-title", "文件传输助手", 0.2135, 0.1338, 0.29, 0.0231)

    private static func run(_ mode: Mode, frame: ScreenFrame, directory: URL, recording: Bool) async -> Result {
        var fullCalls = 0, roiCalls = 0, clock = 0.0
        let executor = MouseExecutor()
        let versions = RunVersionIdentity(appVersion: "offline", appBuild: "fixture", sourceRevision: "injected-metrics-check",
            harnessVersion: "fixture", firmwareVersion: "none", model: "none", endpointHost: "none", device: "host-fake",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString, executionKind: .offlineReplay)
        // The controlled clock verifies attribution only; these are not measured OCR durations.
        let recorder = recording ? RunMetricsRecorder(taskID: UUID(), versions: versions, directory: nil, clock: { clock }) : nil
        let initialNotes = recorder?.snapshot.measurementNotes ?? []
        let runtime = PhoneHarnessRuntime(executor: executor, memoryURL: directory.appendingPathComponent(UUID().uuidString + ".json"), recognize: { _ in
            fullCalls += 1; clock += 2
            if mode == .fullThrow { throw RuntimeMetricsSyntheticError.recognition }
            if mode == .fullCancellation { throw CancellationError() }
            if mode == .fullReturnThenCancel { withUnsafeCurrentTask { $0?.cancel() } }
            if mode == .fullReturnThenAccessoryChange { executor.ble.selectedID = "other-offline-accessory" }
            return mode == .nonCandidateAndHit ? [] : candidate
        }, recognizeWorkflowTitle: { _ in
            roiCalls += 1; clock += 7
            if mode == .roiThrow { throw RuntimeMetricsSyntheticError.recognition }
            if mode == .roiCancellation { throw CancellationError() }
            if mode == .roiReturnThenCancel { withUnsafeCurrentTask { $0?.cancel() } }
            if mode == .roiReturnThenAccessoryChange { executor.ble.selectedID = "other-offline-accessory" }
            return mode == .emptyAndHit ? [] : [title]
        })
        runtime.metrics = recorder
        let operation = Task { @MainActor () -> ([PhoneUISnapshot], String) in
            var snapshots: [PhoneUISnapshot] = []
            do {
                snapshots.append(try await runtime.workflowSnapshot(frame))
                if mode.readsCache {
                    if mode == .cancelledCacheHit { withUnsafeCurrentTask { $0?.cancel() } }
                    let next = mode == .staleCacheHit ? frame.confirmed(at: Date().addingTimeInterval(-2)) : frame.confirmed(at: Date())
                    snapshots.append(try await runtime.workflowSnapshot(next))
                }
                return (snapshots, "none")
            } catch is CancellationError { return (snapshots, "CancellationError") }
            catch is RuntimeMetricsSyntheticError { return (snapshots, "RuntimeMetricsSyntheticError") }
            catch is PhoneHarnessFallback { return (snapshots, "PhoneHarnessFallback") }
            catch { return (snapshots, "unexpected:" + String(reflecting: type(of: error))) }
        }
        let (snapshots, error) = await operation.value
        return Result(fullCalls: fullCalls, roiCalls: roiCalls, snapshots: snapshots, error: error,
            clock: clock, metrics: recorder?.snapshot, initialNotes: initialNotes, inputs: executor.actions.count)
    }

    static func run(directory: URL, reportURL: URL? = nil) async throws -> Int {
        var checks = 0, cases: [[String: Any]] = []
        let modelCalls = ModelProbe.calls
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func record(_ mode: String, enabled: Result, disabled: Result) throws {
            var entry: [String: Any] = ["case": mode, "fullCalls": enabled.fullCalls, "roiCalls": enabled.roiCalls,
                "acceptedSnapshots": enabled.snapshots.count, "error": enabled.error,
                "injectedClockSeconds": enabled.clock, "inputCalls": enabled.inputs,
                "nilMetrics": ["fullCalls": disabled.fullCalls, "roiCalls": disabled.roiCalls,
                    "acceptedSnapshots": disabled.snapshots.count, "error": disabled.error, "inputCalls": disabled.inputs]]
            if let metrics = enabled.metrics { entry["metrics"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(metrics)) }
            cases.append(entry)
            if let reportURL {
                try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: ["offlineInjectedOnly": true, "syntheticTimingOnly": true, "cases": cases], options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
            }
        }
        let fixedLabels: Set<String> = ["harness.current-frame", "harness.workflow-title", "harness.page-identity",
            "harness.current-frame-binding", "harness.workflow-frame-binding", "harness.workflow-title-binding"]
        let note = "OCR completed records recognition return only; post-recognition binding checks determine whether results are accepted."
        for mode in Mode.allCases {
            let frame = ScreenFrame(capturedAt: Date().addingTimeInterval(-5), captureID: UUID()).confirmed(at: Date())
            let enabled = await run(mode, frame: frame, directory: directory, recording: true)
            let disabled = await run(mode, frame: frame, directory: directory, recording: false)
            // Persist actual calls, outcomes, error and spans before assertions.
            try record(mode.rawValue, enabled: enabled, disabled: disabled)
            let metrics = enabled.metrics!, spans = metrics.spans
            func matching(_ label: String) -> [RunTimingSpan] { spans.filter { $0.label == label } }
            let full = matching("harness.current-frame"), roi = matching("harness.workflow-title")
            let fullBinding = matching("harness.current-frame-binding"), frameBinding = matching("harness.workflow-frame-binding")
            let titleBinding = matching("harness.workflow-title-binding")
            expect(enabled.inputs == 0 && disabled.inputs == 0 && ModelProbe.calls == modelCalls, mode.rawValue + ": metrics never cause model or input actions")
            expect(disabled.metrics == nil && enabled.fullCalls == disabled.fullCalls && enabled.roiCalls == disabled.roiCalls &&
                   enabled.snapshots == disabled.snapshots && enabled.error == disabled.error,
                   mode.rawValue + ": nil metrics preserves observations, original error kinds, cache behavior and source timestamps")
            expect(enabled.fullCalls == 1 && enabled.roiCalls == (mode.hasROI ? 1 : 0) && full.count == 1 && roi.count == enabled.roiCalls,
                   mode.rawValue + ": one actual recognition miss produces exactly one OCR span; hits never inflate counts")
            expect(Set(spans.map(\.label)).isSubset(of: fixedLabels) && metrics.measurementNotes == enabled.initialNotes + [note],
                   mode.rawValue + ": fixed labels and one static note contain no observed account, OCR text or device identity")
            expect(spans.allSatisfy { $0.end != nil && $0.outcome != nil && $0.end! >= $0.start }, mode.rawValue + ": every measured operation has a closed outcome")
            expect(abs(full[0].end! - full[0].start - 2) < 0.000001 &&
                   roi.allSatisfy { abs($0.end! - $0.start - 7) < 0.000001 },
                   mode.rawValue + ": each OCR duration covers only its injected recognizer")
            let accounted = metrics.timing.exclusiveSeconds.values.reduce(0, +) + metrics.timing.unattributedSeconds
            expect(abs(accounted - enabled.clock) < 0.000001 && abs(metrics.elapsedSeconds - enabled.clock) < 0.000001 &&
                   abs((metrics.timing.inclusiveSeconds["ocr"] ?? 0) - enabled.clock) < 0.000001 && metrics.timing.unattributedSeconds == 0,
                   mode.rawValue + ": complete OCR attribution reconciles with end-to-end synthetic clock")
            let expectedFull: RunStageOutcome = mode == .fullThrow ? .failed : mode == .fullCancellation ? .cancelled : .completed
            let expectedROI: RunStageOutcome = mode == .roiThrow ? .failed : mode == .roiCancellation ? .cancelled : .completed
            expect(full[0].outcome == expectedFull && roi.allSatisfy { $0.outcome == expectedROI },
                   mode.rawValue + ": recognizer return, throw and cancellation retain distinct outcomes")
            if [.fullThrow, .fullCancellation].contains(mode) {
                expect(fullBinding.isEmpty && frameBinding.isEmpty && titleBinding.isEmpty && enabled.snapshots.isEmpty,
                       mode.rawValue + ": no post-recognition guard or result exists after a recognizer throws")
            } else if [.fullReturnThenCancel, .fullReturnThenAccessoryChange].contains(mode) {
                let expected: RunStageOutcome = mode == .fullReturnThenCancel ? .cancelled : .failed
                expect(fullBinding.count == 1 && fullBinding[0].outcome == expected && frameBinding.isEmpty && titleBinding.isEmpty && enabled.snapshots.isEmpty,
                       mode.rawValue + ": completed full OCR cannot hide a rejected binding or reach ROI")
            } else {
                let hits = [.successAndHit, .emptyAndHit, .nonCandidateAndHit].contains(mode) ? 2 : 1
                expect(fullBinding.count == 1 && fullBinding[0].outcome == .completed &&
                       frameBinding.count == hits && frameBinding.allSatisfy { $0.outcome == .completed },
                       mode.rawValue + ": original full and workflow guards remain in order, including each accepted hit")
                if [.roiThrow, .roiCancellation, .nonCandidateAndHit].contains(mode) {
                    expect(titleBinding.isEmpty, mode.rawValue + ": title binding is absent unless ROI actually returns")
                } else {
                    let expected: RunStageOutcome = mode == .roiReturnThenCancel ? .cancelled : mode == .roiReturnThenAccessoryChange ? .failed : .completed
                    expect(titleBinding.count == 1 && titleBinding[0].outcome == expected,
                           mode.rawValue + ": ROI returned recognition is independently accepted or rejected by its original guard")
                }
            }
            switch mode {
            case .successAndHit:
                expect(enabled.snapshots.count == 2 && enabled.snapshots.allSatisfy { $0.elements.contains { $0.label == title.label } }, "A successful ROI and its cache hit preserve the actual title")
            case .emptyAndHit, .nonCandidateAndHit:
                expect(enabled.snapshots.count == 2 && enabled.snapshots.allSatisfy { !$0.elements.contains { $0.label == title.label } }, "Empty/noncandidate recognition cannot manufacture a title")
            case .staleCacheHit:
                expect(enabled.snapshots.count == 1 && enabled.error == "PhoneHarnessFallback" && spans.count == 6,
                       "A stale cache hit still fails original freshness before generating further spans")
            case .cancelledCacheHit:
                expect(enabled.snapshots.count == 1 && enabled.error == "CancellationError" && spans.count == 6,
                       "A cancelled cache hit still fails original cancellation before generating further spans")
            case .fullThrow, .roiThrow:
                expect(enabled.snapshots.isEmpty && enabled.error == "RuntimeMetricsSyntheticError", "Recognizer errors preserve their original type")
            case .fullCancellation, .roiCancellation, .fullReturnThenCancel, .roiReturnThenCancel:
                expect(enabled.snapshots.isEmpty && enabled.error == "CancellationError", "Cancellation never supplies a snapshot or becomes an ordinary OCR error")
            case .fullReturnThenAccessoryChange, .roiReturnThenAccessoryChange:
                expect(enabled.snapshots.isEmpty && enabled.error == "PhoneHarnessFallback", "A changed accessory rejects recognized results rather than accepting a completed OCR span")
            }
        }
        return checks
    }
}
