import Foundation

@main struct RunMetricsChecks {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1; if !value() { fatalError(message) }
    }
    static func versions(_ kind: RunExecutionKind = .offlineReplay) -> RunVersionIdentity {
        RunVersionIdentity(appVersion: "1", appBuild: "test", sourceRevision: "fixture", harnessVersion: "fixture",
            firmwareVersion: "unknown", model: "offline-no-provider", endpointHost: "none", device: "offline-clock", operatingSystem: "fixture", executionKind: kind)
    }
    static func conditions() -> RunInitialConditions {
        RunInitialConditions(taskKey: "instrumentation-fixture", comparisonKey: "deterministic-clock-scope-v1", confirmed: true,
            initialPage: "fixture", searchState: "cleared", clipboardState: "none", bodyPreparation: "none", connectedToMac: true)
    }
    static func sample(_ seconds: Double, outcome: RunAttemptOutcome = .completed) -> AgentRunMetrics {
        var time = 100.0
        let recorder = RunMetricsRecorder(taskID: UUID(), versions: versions(), conditions: conditions(), directory: nil, clock: { time })
        let model = recorder.begin(.model, label: "fixture model")
        time += seconds / 2; recorder.end(model)
        time += seconds / 2
        recorder.finish(outcome, correctness: outcome == .completed ? .verified : .unknown, evidence: "Synthetic clock fixture only", sideEffectErrors: 0)
        return recorder.snapshot
    }
    static func main() async throws {
        var time = 10.0
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let r = RunMetricsRecorder(taskID: UUID(), versions: versions(), directory: directory, clock: { time })
        let outer = r.begin(.harness, label: "macro")
        time = 11; let ocr = r.begin(.ocr, label: "local OCR", parentID: outer)
        time = 13; r.end(ocr)
        let input = r.begin(.input, label: "real input boundary", parentID: outer)
        time = 15; r.end(input)
        time = 16; r.end(outer)
        time = 18; r.finish(.partial, correctness: .partial, evidence: "Only a fragment was checked")
        let s = r.snapshot
        expect(s.elapsedSeconds == 8, "monotonic end-to-end")
        expect(s.timing.exclusiveSeconds["ocr"] == 2, "nested OCR attribution")
        expect(s.timing.exclusiveSeconds["input"] == 2, "nested input attribution")
        expect(s.timing.exclusiveSeconds["harness"] == 2, "parent excludes children")
        expect(s.timing.inclusiveSeconds["harness"] == 6, "inclusive macro diagnostic")
        expect(s.timing.unattributedSeconds == 2, "unattributed explicit")
        expect(s.timing.exclusiveSeconds.values.reduce(0, +) + s.timing.unattributedSeconds == s.elapsedSeconds, "no double counting")
        expect(!s.isVerifiedSuccess, "partial correctness is not success")
        time = 100; expect(r.snapshot.elapsedSeconds == 8, "finished duration immutable")
        r.finish(.completed, correctness: .verified, evidence: "late overwrite", sideEffectErrors: 0)
        expect(r.snapshot.outcome == .partial, "late result cannot overwrite")
        let file = directory.appendingPathComponent(s.id.uuidString + ".json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(AgentRunMetrics.self, from: Data(contentsOf: file))
        expect(saved.id == s.id && saved.elapsedSeconds == 8 && saved.spans.count == 3, "durable attempt JSON")
        expect(saved.discardedTimingSpans == nil, "older metric files without a truncation counter remain readable")
        expect(saved.versions.firmwareVersion == "unknown", "firmware cannot be invented")
        expect(saved.conditions.confirmed == false, "runtime conditions unconfirmed by default")
        let r2 = RunMetricsRecorder(taskID: UUID(), versions: versions(), directory: nil, clock: { time })
        enum Expected: Error { case failed }
        do { try r2.measure(.model, label: "failing model") { throw Expected.failed } } catch {}
        expect(r2.snapshot.modelRequests == 1, "failed model request counted")
        expect(r2.snapshot.spans.last?.outcome == .failed, "throwing stage ends as failed")
        do { try await r2.measureAsync(.input, label: "cancelled input") { throw CancellationError() } } catch {}
        expect(r2.snapshot.spans.last?.outcome == .cancelled, "cancelled stage preserved")
        let running = r2.begin(.wait, label: "incomplete wait")
        time += 2; r2.finish(.cancelled, evidence: "User stopped")
        expect(r2.snapshot.spans.first(where: { $0.id == running })?.outcome == .cancelled, "open spans closed on cancellation")
        let overlap = RunTimingBreakdown.calculate(spans: [
            RunTimingSpan(id: UUID(), category: .harness, label: "outer", start: 0, end: 8),
            RunTimingSpan(id: UUID(), category: .wait, label: "later operation", start: 2, end: 5)
        ], elapsed: 10)
        expect(overlap.exclusiveSeconds["harness"] == 5 && overlap.exclusiveSeconds["wait"] == 3 && overlap.unattributedSeconds == 2, "callback spans without parent do not double count")
        let malformed = RunTimingBreakdown.calculate(spans: [RunTimingSpan(id: UUID(), category: .ocr, label: "invalid", start: .nan)], elapsed: 5)
        expect(malformed.unattributedSeconds == 5, "invalid time cannot contaminate report")
        let longRun = (0..<4000).map { index in
            RunTimingSpan(id: UUID(), category: .wait, label: "bounded polling", start: Double(index) * 0.005, end: Double(index + 1) * 0.005)
        }
        let longTiming = RunTimingBreakdown.calculate(spans: longRun, elapsed: 20)
        expect(abs((longTiming.exclusiveSeconds["wait"] ?? 0) - 20) < 0.00001 && longTiming.unattributedSeconds < 0.00001, "long telemetry runs reconcile without repeated full-span scans")

        var longTime = 1_000.0
        let longTaskID = UUID()
        let boundedRecorder = RunMetricsRecorder(taskID: longTaskID, versions: versions(), conditions: conditions(),
            directory: nil, clock: { longTime })
        let retainedParent = boundedRecorder.begin(.harness, label: "long-running open operation")
        let attemptID = boundedRecorder.snapshot.id
        let requests = RunMetricsRecorder.maximumRetainedTimingSpans + 25
        for _ in 0..<requests {
            longTime += 0.001
            let request = boundedRecorder.begin(.model, label: "long-task model", parentID: retainedParent)
            longTime += 0.001; boundedRecorder.end(request)
        }
        let boundedOpen = boundedRecorder.snapshot
        expect(boundedOpen.spans.count <= RunMetricsRecorder.maximumRetainedTimingSpans,
               "long tasks retain a bounded raw timing window")
        expect((boundedOpen.discardedTimingSpans ?? 0) > 0 &&
               boundedOpen.spans.count + (boundedOpen.discardedTimingSpans ?? 0) == requests + 1,
               "discarded raw spans are counted instead of silently losing evidence")
        expect(boundedOpen.spans.first(where: { $0.id == retainedParent })?.end == nil,
               "old open spans survive raw telemetry pruning")
        boundedRecorder.end(retainedParent)
        boundedRecorder.finish(.completed, correctness: .verified, evidence: "Synthetic long-run telemetry fixture", sideEffectErrors: 0)
        let bounded = boundedRecorder.snapshot
        expect(bounded.spans.first(where: { $0.id == retainedParent })?.outcome == .completed,
               "a retained old open span can still close after pruning")
        expect(bounded.id == attemptID && bounded.taskID == longTaskID && bounded.modelRequests == requests,
               "telemetry truncation preserves attempt identity and the total model-request count")
        expect(bounded.elapsedSeconds == longTime - 1_000 && bounded.outcome == .completed,
               "telemetry truncation preserves whole-attempt elapsed time and outcome")
        expect(bounded.measurementNotes.contains(where: { $0.contains("category timings are incomplete") }),
               "truncated timings disclose their limits")
        let callbackRecorder = RunMetricsRecorder(taskID: UUID(), versions: versions(), directory: nil, clock: { longTime })
        for _ in 0...RunMetricsRecorder.maximumRetainedTimingSpans {
            callbackRecorder.recordInterval(.upload, label: "transport callback", startUptime: longTime, endUptime: longTime)
        }
        let boundedCallbacks = callbackRecorder.snapshot
        expect(boundedCallbacks.spans.count <= RunMetricsRecorder.maximumRetainedTimingSpans &&
               (boundedCallbacks.discardedTimingSpans ?? 0) > 0,
               "transport callback intervals cannot bypass the telemetry bound")

        let before = [sample(10), sample(30, outcome: .failed), sample(20)]
        let after = [sample(6), sample(12, outcome: .partial), sample(9)]
        let report = RunBenchmarkComparison.compare(before: before, after: after)
        expect(report.comparable && report.before.samples == 3 && report.after.samples == 3, "three samples each")
        expect(report.before.medianSeconds == 20 && report.before.minimumSeconds == 10 && report.before.maximumSeconds == 30, "median and range include failed attempts")
        expect(report.before.outcomeCounts["failed"] == 1 && report.after.outcomeCounts["partial"] == 1, "all outcomes counted")
        expect(report.before.verifiedSuccesses == 2 && report.after.verifiedSuccesses == 2, "accuracy denominator includes failures and partials")
        expect(abs((report.medianReductionFraction ?? 0) - 0.55) < 0.00001, "recomputable ratio on synthetic clocks")
        expect(report.after.executionKind == .offlineReplay && report.interpretation.contains("never device speed"), "offline evidence explicitly labelled")
        expect(!RunBenchmarkComparison.compare(before: [before[0]], after: after).comparable, "insufficient sample blocked")
        var device = after; device[0].versions.executionKind = .deviceGUI
        expect(!RunBenchmarkComparison.compare(before: before, after: device).comparable, "mixed device and replay blocked")
        var unknown = after; unknown[0].conditions.confirmed = false
        expect(!RunBenchmarkComparison.compare(before: before, after: unknown).comparable, "unconfirmed conditions blocked")
        var changed = after; changed[0].versions.model = "different"
        expect(!RunBenchmarkComparison.compare(before: before, after: changed).comparable, "different model blocked")
        var unknownEffect = before; unknownEffect[0].sideEffectErrors = nil
        expect(RunBenchmarkComparison.summarize(unknownEffect).sideEffectErrors == nil, "unknown side effects never zero")
        var unverified = before[0]; unverified.correctness = .unknown
        expect(!unverified.isVerifiedSuccess, "model-declared completion not independent correctness")
        expect(RunBenchmarkComparison.summarize([]).samples == 0, "empty report safe")
        for raw in ["unknown", "unknown-use-build-verified-script", "$(PHONE_AGENT_SOURCE_REVISION)", "${SOURCE_REVISION}", "placeholder", "unverified-local", " "] {
            var identity = versions(); identity.sourceRevision = raw
            expect(!identity.installationTraceable, "unexpanded or placeholder source identity is not traceable")
        }
        var unresolvedBuild = versions(); unresolvedBuild.appBuild = "$(CURRENT_PROJECT_VERSION)"
        expect(!unresolvedBuild.installationTraceable, "unexpanded build is not traceable")
        expect(versions().installationTraceable, "resolved fixture identity is traceable")
        expect(!report.correctnessAccepted && !report.eligibleForDeviceAcceptance, "failed or offline samples cannot pass device acceptance")
        expect(report.before.exclusiveTimingByCategory["model"]?.observedAttempts == 3, "per-category sample counts exposed")
        expect(report.before.exclusiveTimingByCategory["upload"]?.medianSeconds == nil, "missing upload remains unknown, not zero")
        let truncatedReport = RunBenchmarkComparison.compare(before: [bounded, before[1], before[2]], after: after)
        expect(!truncatedReport.comparable && truncatedReport.medianReductionFraction == nil &&
               !truncatedReport.eligibleForDeviceAcceptance &&
               truncatedReport.unavailableReasons.contains(where: { $0.contains("Timing spans were discarded") }),
               "truncated timing evidence cannot establish benchmark speedup or device acceptance")

        if CommandLine.arguments.count == 2 {
            struct FixtureReport: Codable { var evidenceKind = "offlineReplay - synthetic monotonic clock tests only"; var before: [AgentRunMetrics]; var after: [AgentRunMetrics]; var comparison: RunBenchmarkComparison }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(FixtureReport(before: before, after: after, comparison: report)).write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        }
        print("Run metrics checks passed: \(checks) (offline instrumentation only; no device speed or task acceptance claim)")
    }
}
