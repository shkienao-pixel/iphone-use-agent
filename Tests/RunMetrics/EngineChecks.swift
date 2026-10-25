import Foundation

@MainActor final class PendingReviewHarness: PhoneHarnessDriving {
    var hasPendingReview = false
    var taskScopeID: UUID?
    var executions = 0
    func context(for frame: ScreenFrame) async throws -> String { "offline pending-review test" }
    func didExecute(_ action: AgentAction, frame: ScreenFrame) async {}
    func execute(_ request: PhoneHarnessRequest, frame: ScreenFrame, mappedHome: Bool,
                 nextFrame: @escaping @MainActor (Date) async throws -> ScreenFrame) async throws -> PhoneHarnessReceipt {
        executions += 1; hasPendingReview = true
        ModelProbe.action = AgentAction(kind: .type, text: "must not be sent", reason: "attempt generic-input bypass")
        return PhoneHarnessReceipt(summary: "unknown submission", verifiedFrame: nil,
            lastInputCompletedAt: Date(), requiresUserReview: true)
    }
}

@main struct EngineMetricsChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message); checks += 1 }
        func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !condition() { precondition(Date() < deadline, "metrics integration timed out"); try await Task.sleep(nanoseconds: 10_000_000) }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EngineMetrics-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); PrivacyConsent.revoke() }
        let engine = AgentEngine(capture: CaptureService(), executor: MouseExecutor())
        engine.metricsDirectory = directory
        var settings = AgentSettings(); settings.startDelay = 0; settings.stepInterval = 0.4
        ModelProbe.delay = 0; ModelProbe.calls = 0; ModelProbe.action = AgentAction(kind: .finish, reason: "offline completion claim")
        PrivacyConsent.revoke(); engine.start(task: "offline trace", settings: settings)
        expect(!engine.running && ModelProbe.calls == 0, "preflight failure dispatches nothing")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        func attempts() throws -> [AgentRunMetrics] {
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).map { try decoder.decode(AgentRunMetrics.self, from: Data(contentsOf: $0)) }
        }
        let rejected = try attempts()
        expect(rejected.count == 1 && rejected[0].outcome == .failed, "preflight failure counted durably")
        expect(rejected[0].spans.contains { $0.category == .preparation && $0.outcome == .failed }, "readiness timing includes failure")
        PrivacyConsent.grant(settings); engine.start(task: "offline trace", settings: settings)
        try await waitUntil { engine.executionSettled }
        let complete = engine.runMetrics!.snapshot
        expect(complete.outcome == .completed && complete.finishedAt != nil, "task terminal result closes attempt")
        expect(complete.modelRequests == 1, "engine passes recorder to model transport")
        expect(complete.correctness == .unknown && !complete.isVerifiedSuccess, "model finish does not prove correctness")
        expect(complete.versions.executionKind == .offlineReplay, "offline engine cannot impersonate device evidence")
        expect(!complete.conditions.confirmed && complete.conditions.clipboardState == "unknown", "unknown starting states retained")
        expect(complete.spans.contains { $0.category == .capture } && complete.spans.contains { $0.category == .verification }, "actual production capture and validation timed")
        let sum = complete.timing.exclusiveSeconds.values.reduce(0, +) + complete.timing.unattributedSeconds
        expect(abs(sum - complete.elapsedSeconds) < 0.0001, "production loop attribution reconciles")
        ModelProbe.delay = 1_000_000_000
        var fixed = RunInitialConditions(); fixed.taskKey = "fixed-task"; fixed.comparisonKey = "fixed-condition"
        fixed.initialPage = "fixture-home"; fixed.searchState = "clear"; fixed.clipboardState = "none"; fixed.bodyPreparation = "none"
        fixed.connectedToMac = true; fixed.confirmed = true
        engine.initialRunConditions = fixed
        engine.start(task: "offline cancelled trace", settings: settings)
        try await waitUntil { ModelProbe.calls == 2 }
        let cancelledID = engine.runMetrics!.snapshot.id, taskID = engine.currentRecord!.id
        expect(engine.runMetrics!.snapshot.conditions == fixed, "confirmed UI conditions copied into only this attempt")
        expect(!engine.initialRunConditions.confirmed, "confirmed conditions consumed once")
        engine.pause(); try await waitUntil { engine.executionSettled }
        let cancelled = engine.runMetrics!.snapshot
        expect(cancelled.outcome == .cancelled && cancelled.finishedAt != nil, "pause closes attempt after input release")
        expect(cancelled.spans.contains { $0.category == .model && $0.outcome == .cancelled }, "in-flight model cancellation counted")
        ModelProbe.delay = 0; engine.resume(delay: 2); try await waitUntil { engine.executionSettled }
        let resumed = engine.runMetrics!.snapshot
        expect(!resumed.conditions.confirmed, "resume requires fresh initial-state confirmation")
        expect(resumed.id != cancelledID && resumed.taskID == taskID, "resume is another attempt with the same task ID")
        expect(resumed.spans.contains { $0.category == .wait }, "real resume delay included")
        let all = try attempts()
        expect(all.count == 4, "all failure, completion, cancellation and resume attempts retained")
        expect(all.filter { $0.taskID == taskID }.count == 2, "durable resume identity links both attempts")
        let guarded = AgentEngine(capture: CaptureService(), executor: MouseExecutor())
        let harness = PendingReviewHarness(); guarded.phoneHarness = harness
        ModelProbe.calls = 0
        ModelProbe.action = AgentAction(kind: .phone_tool, text: #"{"operation":"open_search"}"#, reason: "uncertain local workflow")
        var confirmed = RunInitialConditions(); confirmed.confirmed = true; confirmed.taskKey = "fixed-test"
        guarded.initialRunConditions = confirmed
        guarded.start(task: "one test operation only", settings: settings)
        try await waitUntil { guarded.executionSettled }
        expect(guarded.phase == .needsUser && !guarded.running, "uncertain side effect hard-stops execution")
        expect(ModelProbe.calls == 1 && harness.executions == 1, "no second model decision after uncertain result")
        expect(guarded.executor.actions.isEmpty, "generic input cannot bypass pending workflow")
        expect(guarded.runMetrics?.snapshot.outcome == .partial, "unknown operation not counted completed")
        expect(harness.taskScopeID == guarded.currentRecord?.id, "host task identity bound to local ledger")
        expect(guarded.runMetrics?.snapshot.conditions.confirmed == true && !guarded.initialRunConditions.confirmed,
               "benchmark starting conditions consumed once")
        guarded.resume(delay: 0)
        expect(!guarded.running && ModelProbe.calls == 1, "resume requires explicit user review first")
        guarded.start(task: "new ID must not bypass unknown result", settings: settings)
        expect(!guarded.running && ModelProbe.calls == 1, "new task cannot bypass unresolved persistent operation")
        print("\(checks) production engine metrics checks passed; fake frames/model/input only, no device benchmark.")
    }
}
