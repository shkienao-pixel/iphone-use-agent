import Foundation

/// These labels describe where evidence was obtained, not a correctness claim.
enum RunExecutionKind: String, Codable { case deviceGUI, simulator, offlineReplay, unknown }
enum RunTimingCategory: String, Codable, CaseIterable {
    case preparation, model, ocr, input, wait, upload, verification, capture, harness, systemTool
}
enum RunStageOutcome: String, Codable { case completed, failed, cancelled }
enum RunAttemptOutcome: String, Codable, CaseIterable { case completed, partial, failed, unknown, cancelled }
enum RunCorrectness: String, Codable { case verified, partial, failed, unknown }

struct RunVersionIdentity: Codable, Equatable {
    var appVersion: String
    var appBuild: String
    var sourceRevision: String
    var harnessVersion: String
    var firmwareVersion: String
    var model: String
    var endpointHost: String
    var device: String
    var operatingSystem: String
    var executionKind: RunExecutionKind
    /// A missing firmware/source identity must remain unknown, never inferred
    /// from this checkout or from a successful connection.
    static func usableIdentity(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !value.isEmpty && !value.contains("unknown") && !value.contains("placeholder")
            && !value.contains("unverified") && !value.contains("$(") && !value.contains("${")
            && !value.contains("\n") && !value.contains("\r")
    }
    var installationTraceable: Bool {
        [appVersion, appBuild, sourceRevision, harnessVersion].allSatisfy(Self.usableIdentity)
    }
}

struct RunInitialConditions: Codable, Equatable {
    var taskKey = "unspecified"
    var comparisonKey = "unknown"
    var confirmed = false
    var initialPage = "unknown"
    var searchState = "unknown"
    var clipboardState = "unknown"
    var bodyPreparation = "unknown"
    var connectedToMac: Bool?
    var humanInterventions = 0
    // No task text, clipboard contents, account IDs, or API credentials belong here.
}

struct RunCaptureIdentity: Codable, Equatable {
    var captureID: UUID?
    var width: Int
    var height: Int
    var sourceWidth: Int
    var sourceHeight: Int
}

struct RunTimingSpan: Codable, Identifiable {
    var id: UUID
    var parentID: UUID?
    var category: RunTimingCategory
    var label: String
    var start: Double
    var end: Double?
    var outcome: RunStageOutcome?
}

struct RunTimingBreakdown: Codable {
    /// Exclusive categories partition elapsed time: nested/overlapping spans are
    /// never added twice. Inclusive values are separate diagnostic unions.
    var exclusiveSeconds: [String: Double]
    var inclusiveSeconds: [String: Double]
    var unattributedSeconds: Double
    var overlappingSeconds: Double
    var attributionExplanation: String

    static func calculate(spans: [RunTimingSpan], elapsed: Double) -> RunTimingBreakdown {
        let elapsed = elapsed.isFinite ? max(0, elapsed) : 0
        let valid = spans.filter { $0.start.isFinite && ($0.end ?? elapsed).isFinite && $0.start >= 0 && ($0.end ?? elapsed) >= $0.start }
        let byID = Dictionary(valid.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func depth(_ span: RunTimingSpan) -> Int {
            var depth = 0, parent = span.parentID, visited: Set<UUID> = [span.id]
            while let id = parent, let ancestor = byID[id], !visited.contains(id) {
                visited.insert(id); depth += 1; parent = ancestor.parentID
            }
            return depth
        }
        let depths = valid.map(depth)
        struct Event { var time: Double; var index: Int; var beginning: Bool }
        var events: [Event] = []
        for (index, span) in valid.enumerated() {
            let start = min(elapsed, span.start), end = min(elapsed, span.end ?? elapsed)
            guard end > start else { continue }
            events.append(Event(time: start, index: index, beginning: true))
            events.append(Event(time: end, index: index, beginning: false))
        }
        events.sort { $0.time < $1.time }
        var exclusive: [String: Double] = [:], inclusive: [String: Double] = [:]
        var unassigned = 0.0, overlapping = 0.0, previous = 0.0
        var active = Set<Int>(), cursor = 0
        // Sweep intervals once instead of scanning all previous spans at each
        // boundary. Long runs keep telemetry overhead close to O(n log n).
        while cursor < events.count {
            let boundary = events[cursor].time, duration = boundary - previous
            if duration > 0 {
                if active.isEmpty { unassigned += duration }
                else {
                    for category in Set(active.map { valid[$0].category.rawValue }) { inclusive[category, default: 0] += duration }
                    if active.count > 1 { overlapping += duration }
                    let leaf = active.max { left, right in
                        if depths[left] != depths[right] { return depths[left] < depths[right] }
                        if valid[left].start != valid[right].start { return valid[left].start < valid[right].start }
                        return valid[left].id.uuidString < valid[right].id.uuidString
                    }!
                    exclusive[valid[leaf].category.rawValue, default: 0] += duration
                }
            }
            while cursor < events.count && events[cursor].time == boundary {
                let event = events[cursor]
                if event.beginning { active.insert(event.index) } else { active.remove(event.index) }
                cursor += 1
            }
            previous = boundary
        }
        if previous < elapsed { unassigned += elapsed - previous }
        return RunTimingBreakdown(exclusiveSeconds: exclusive, inclusiveSeconds: inclusive,
            unattributedSeconds: unassigned, overlappingSeconds: overlapping,
            attributionExplanation: "Exclusive categories plus unattributed equal end-to-end elapsed. Inclusive categories are diagnostic unions and must not be summed. Explicit descendants win overlaps; otherwise the latest-started span wins. Unattributed includes event-loop scheduling, local bookkeeping, logging, and any uninstrumented operation.")
    }
}

struct AgentRunMetrics: Codable, Identifiable {
    var schemaVersion = 1
    var id: UUID
    var taskID: UUID
    var startedAt: Date
    var finishedAt: Date?
    var versions: RunVersionIdentity
    var conditions: RunInitialConditions
    var captures: [RunCaptureIdentity]
    var spans: [RunTimingSpan]
    var elapsedSeconds: Double
    var modelRequests: Int
    var outcome: RunAttemptOutcome
    var correctness: RunCorrectness
    var resultEvidence: String
    var sideEffectErrors: Int?
    var timing: RunTimingBreakdown
    // Optional so existing metric files remain readable. Whole-attempt counts
    // and elapsed time are preserved even when older raw timings are discarded.
    var discardedTimingSpans: Int? = nil
    var persistenceError: String?
    var measurementNotes: [String] = ["Missing timing categories mean not measured, never zero. Model inclusive time includes prompt preparation, transport and server inference. Upload is reported only when URLSession supplies request transaction timestamps."]
    var isVerifiedSuccess: Bool { outcome == .completed && correctness == .verified && sideEffectErrors == 0 }
}

/// Uses a monotonic clock for durations and wall time only for trace timestamps.
/// A recorder is scoped to one launch attempt; resuming creates another attempt
/// with the same task ID, so cancellations and failures remain in the denominator.
final class RunMetricsRecorder: @unchecked Sendable {
    static let maximumRetainedTimingSpans = 10_000
    private let lock = NSRecursiveLock()
    private let clock: () -> Double
    private let started: Double
    private let directory: URL?
    private var value: AgentRunMetrics
    private var lastPersisted: Double = -.infinity

    init(taskID: UUID, versions: RunVersionIdentity, conditions: RunInitialConditions = RunInitialConditions(),
         directory: URL? = RunMetricsRecorder.defaultDirectory,
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }, now: Date = Date()) {
        self.clock = clock; self.directory = directory; started = clock()
        value = AgentRunMetrics(id: UUID(), taskID: taskID, startedAt: now, versions: versions,
            conditions: conditions, captures: [], spans: [], elapsedSeconds: 0, modelRequests: 0,
            outcome: .unknown, correctness: .unknown, resultEvidence: "Running; result not independently verified.",
            timing: .calculate(spans: [], elapsed: 0))
        persist(force: true)
    }
    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PhoneAgent/RunMetrics", isDirectory: true)
    }
    private var offset: Double { max(0, clock() - started) }
    @discardableResult func begin(_ category: RunTimingCategory, label: String, parentID: UUID? = nil) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let id = UUID()
        guard value.finishedAt == nil else { return id }
        value.spans.append(RunTimingSpan(id: id, parentID: parentID, category: category,
            label: String(label.prefix(120)), start: offset))
        if category == .model { value.modelRequests += 1 }
        pruneCompletedTimingSpans()
        persist()
        return id
    }
    func end(_ id: UUID, outcome: RunStageOutcome = .completed) {
        lock.lock(); defer { lock.unlock() }
        guard let index = value.spans.firstIndex(where: { $0.id == id }), value.spans[index].end == nil else { return }
        value.spans[index].end = offset; value.spans[index].outcome = outcome
        pruneCompletedTimingSpans()
        persist()
    }
    func measure<T>(_ category: RunTimingCategory, label: String, parentID: UUID? = nil,
                    _ operation: () throws -> T) rethrows -> T {
        let id = begin(category, label: label, parentID: parentID)
        do { let result = try operation(); end(id); return result }
        catch { end(id, outcome: error is CancellationError ? .cancelled : .failed); throw error }
    }
    func measureAsync<T>(_ category: RunTimingCategory, label: String, parentID: UUID? = nil,
                         _ operation: () async throws -> T) async rethrows -> T {
        let id = begin(category, label: label, parentID: parentID)
        do { let result = try await operation(); end(id); return result }
        catch { end(id, outcome: error is CancellationError ? .cancelled : .failed); throw error }
    }
    func note(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        let text = String(text.prefix(240)); if !value.measurementNotes.contains(text) { value.measurementNotes.append(text) }
    }
    /// URLSession supplies wall timestamps. The delegate maps those intervals
    /// onto its request's monotonic anchor before calling this method.
    func recordInterval(_ category: RunTimingCategory, label: String, startUptime: Double, endUptime: Double, parentID: UUID? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard value.finishedAt == nil, startUptime.isFinite, endUptime.isFinite,
              startUptime >= started, endUptime >= startUptime else { return }
        value.spans.append(RunTimingSpan(id: UUID(), parentID: parentID, category: category,
            label: String(label.prefix(120)), start: startUptime - started, end: endUptime - started, outcome: .completed))
        pruneCompletedTimingSpans()
    }
    func recordCapture(_ identity: RunCaptureIdentity) {
        lock.lock(); defer { lock.unlock() }
        if !value.captures.contains(identity) { value.captures.append(identity); persist() }
    }
    func finish(_ outcome: RunAttemptOutcome, correctness: RunCorrectness = .unknown,
                evidence: String, sideEffectErrors: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard value.finishedAt == nil else { return }
        let at = offset
        for index in value.spans.indices where value.spans[index].end == nil {
            value.spans[index].end = at
            value.spans[index].outcome = outcome == .cancelled ? .cancelled : .failed
        }
        value.finishedAt = Date(); value.elapsedSeconds = at; value.outcome = outcome
        value.correctness = correctness; value.resultEvidence = String(evidence.prefix(240)); value.sideEffectErrors = sideEffectErrors
        pruneCompletedTimingSpans()
        persist(force: true)
    }
    private func pruneCompletedTimingSpans() {
        guard value.spans.count > Self.maximumRetainedTimingSpans else { return }
        // Reclaim in batches so every subsequent stage does not copy the whole
        // retained window. Active spans survive until end()/finish() can close
        // them; the cap may temporarily be exceeded by active operations only.
        let target = Self.maximumRetainedTimingSpans - Self.maximumRetainedTimingSpans / 10
        var remaining = value.spans.count - target
        let previousCount = value.spans.count
        value.spans = value.spans.filter { span in
            if span.end != nil && remaining > 0 { remaining -= 1; return false }
            return true
        }
        let discarded = previousCount - value.spans.count
        guard discarded > 0 else { return }
        value.discardedTimingSpans = (value.discardedTimingSpans ?? 0) + discarded
        let note = "Older completed timing spans were discarded to bound long-task telemetry. Attempt identity, total model requests, elapsed time and result remain intact; category timings are incomplete and missing intervals may be unattributed. This attempt is unavailable for benchmark comparison."
        if !value.measurementNotes.contains(note) { value.measurementNotes.append(note) }
    }
    var snapshot: AgentRunMetrics {
        lock.lock(); defer { lock.unlock() }
        var copy = value; copy.elapsedSeconds = value.finishedAt == nil ? offset : value.elapsedSeconds
        copy.timing = .calculate(spans: copy.spans, elapsed: copy.elapsedSeconds)
        return copy
    }
    private func persist(force: Bool = false) {
        guard let directory, force || offset - lastPersisted >= 0.5 else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: directory.appendingPathComponent(value.id.uuidString + ".json"), options: .atomic)
            lastPersisted = offset; value.persistenceError = nil
        } catch {
            // Do not include filesystem paths, task material, or raw provider errors.
            value.persistenceError = "Run metrics could not be persisted; retain the in-memory snapshot and retry export."
        }
    }
}

struct RunCategoryTimingSummary: Codable {
    var observedAttempts: Int
    var medianSeconds: Double?
    var minimumSeconds: Double?
    var maximumSeconds: Double?
}

struct RunBenchmarkSummary: Codable {
    var samples: Int
    var medianSeconds: Double
    var minimumSeconds: Double
    var maximumSeconds: Double
    var medianModelRequests: Double
    var exclusiveTimingByCategory: [String: RunCategoryTimingSummary]
    var medianUnattributedSeconds: Double
    var outcomeCounts: [String: Int]
    var verifiedSuccesses: Int
    var correctnessUnknown: Int
    var sideEffectErrors: Int?
    var humanInterventions: Int
    var executionKind: RunExecutionKind
}

struct RunBenchmarkComparison: Codable {
    var before: RunBenchmarkSummary
    var after: RunBenchmarkSummary
    var comparable: Bool
    var unavailableReasons: [String]
    var medianReductionFraction: Double?
    var interpretation: String
    var correctnessAccepted: Bool
    var eligibleForDeviceAcceptance: Bool

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted(), mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
    static func summarize(_ samples: [AgentRunMetrics]) -> RunBenchmarkSummary {
        let seconds = samples.map { $0.elapsedSeconds }
        var counts = Dictionary(uniqueKeysWithValues: RunAttemptOutcome.allCases.map { ($0.rawValue, 0) })
        samples.forEach { counts[$0.outcome.rawValue, default: 0] += 1 }
        let categories = Dictionary(uniqueKeysWithValues: RunTimingCategory.allCases.map { category in
            let times = samples.compactMap { $0.timing.exclusiveSeconds[category.rawValue] }
            return (category.rawValue, RunCategoryTimingSummary(observedAttempts: times.count,
                medianSeconds: times.isEmpty ? nil : median(times), minimumSeconds: times.min(), maximumSeconds: times.max()))
        })
        return RunBenchmarkSummary(samples: samples.count, medianSeconds: median(seconds), minimumSeconds: seconds.min() ?? 0,
            maximumSeconds: seconds.max() ?? 0, medianModelRequests: median(samples.map { Double($0.modelRequests) }),
            exclusiveTimingByCategory: categories, medianUnattributedSeconds: median(samples.map { $0.timing.unattributedSeconds }),
            outcomeCounts: counts, verifiedSuccesses: samples.filter(\.isVerifiedSuccess).count,
            correctnessUnknown: samples.filter { $0.correctness == .unknown }.count,
            sideEffectErrors: samples.allSatisfy { $0.sideEffectErrors != nil } ? samples.compactMap(\.sideEffectErrors).reduce(0, +) : nil,
            humanInterventions: samples.reduce(0) { $0 + $1.conditions.humanInterventions },
            executionKind: Set(samples.map { $0.versions.executionKind.rawValue }).count == 1 ? samples[0].versions.executionKind : .unknown)
    }
    static func compare(before: [AgentRunMetrics], after: [AgentRunMetrics]) -> RunBenchmarkComparison {
        let all = before + after
        var reasons: [String] = []
        if before.count < 3 || after.count < 3 { reasons.append("At least three attempts per version are required; small samples do not support P95.") }
        if !all.allSatisfy({ $0.versions.installationTraceable && RunVersionIdentity.usableIdentity($0.versions.harnessVersion) }) { reasons.append("Installed app/source/harness identity is incomplete.") }
        if all.contains(where: { $0.versions.executionKind == .deviceGUI && !RunVersionIdentity.usableIdentity($0.versions.firmwareVersion) }) { reasons.append("Device firmware identity is unknown; same-firmware comparison is not established.") }
        if all.contains(where: { $0.finishedAt == nil || !$0.elapsedSeconds.isFinite || $0.elapsedSeconds < 0 }) { reasons.append("Unfinished or invalid attempt.") }
        if all.contains(where: { ($0.discardedTimingSpans ?? 0) > 0 }) { reasons.append("Timing spans were discarded during a long task; incomplete timing evidence cannot support benchmark comparison.") }
        if !all.allSatisfy({ $0.conditions.confirmed && $0.conditions.comparisonKey != "unknown" && $0.conditions.taskKey != "unspecified" }) { reasons.append("Initial conditions and task scope are not confirmed.") }
        if Set(all.map { $0.conditions.initialPage + "|" + $0.conditions.searchState + "|" + $0.conditions.clipboardState + "|" + $0.conditions.bodyPreparation + "|" + String(describing: $0.conditions.connectedToMac) }).count != 1 {
            reasons.append("Initial page, search, clipboard, body preparation, or Mac connection differs.")
        }
        if all.contains(where: { $0.conditions.initialPage == "unknown" || $0.conditions.searchState == "unknown" || $0.conditions.clipboardState == "unknown" || $0.conditions.bodyPreparation == "unknown" || $0.conditions.connectedToMac == nil }) {
            reasons.append("One or more required initial-state fields remain unknown.")
        }
        for group in [before, after] {
            if Set(group.map { $0.versions.sourceRevision + "|" + $0.versions.appBuild + "|" + $0.versions.harnessVersion + "|" + $0.versions.firmwareVersion }).count > 1 {
                reasons.append("A benchmark group mixes installed source, app, harness or firmware versions.")
            }
        }
        if Set(all.map { $0.conditions.comparisonKey }).count != 1 || Set(all.map { $0.conditions.taskKey }).count != 1 { reasons.append("Task scope or initial conditions differ.") }
        if Set(all.map { $0.versions.executionKind.rawValue }).count != 1 || all.contains(where: { $0.versions.executionKind == .unknown }) { reasons.append("Evidence kinds differ or are unknown; replay/simulator and device evidence cannot be combined.") }
        if Set(all.map { $0.versions.model + "|" + $0.versions.endpointHost + "|" + $0.versions.device + "|" + $0.versions.operatingSystem }).count != 1 { reasons.append("Model, endpoint, device, or operating system differs.") }
        let b = summarize(before), a = summarize(after)
        let comparable = reasons.isEmpty && b.medianSeconds > 0
        return RunBenchmarkComparison(before: b, after: a, comparable: comparable, unavailableReasons: reasons,
            medianReductionFraction: comparable ? (b.medianSeconds - a.medianSeconds) / b.medianSeconds : nil,
            interpretation: "All supplied attempts are included, including failures, partial results, cancellations and unknown outcomes. Speed does not establish correctness. offlineReplay/simulator comparisons validate instrumentation only, never device speed or task acceptance. No P95 is reported.",
            correctnessAccepted: !all.isEmpty && all.allSatisfy(\.isVerifiedSuccess),
            eligibleForDeviceAcceptance: comparable && !all.isEmpty && all.allSatisfy { $0.versions.executionKind == .deviceGUI && $0.isVerifiedSuccess })
    }
}
