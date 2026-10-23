import Foundation

@MainActor final class ReceiptHarness: PhoneHarnessDriving {
    enum Result { case verified, stale, wrongStream, partialFailure }
    let capture: CaptureService
    let stream: UUID
    let result: Result
    var finishedAt: Date?
    var wakeupsBeforeNextObservation = 0

    init(capture: CaptureService, stream: UUID, result: Result) {
        self.capture = capture; self.stream = stream; self.result = result
    }
    func context(for frame: ScreenFrame) async throws -> String { "offline harness" }
    func didExecute(_ action: AgentAction, frame: ScreenFrame) async {}
    func execute(_ request: PhoneHarnessRequest, frame: ScreenFrame, mappedHome: Bool,
                 nextFrame: @escaping @MainActor (Date) async throws -> ScreenFrame) async throws -> PhoneHarnessReceipt {
        let inputEnded = Date()
        try await Task.sleep(nanoseconds: 1_000_000)
        // Make the exact final pixels available once. A subsequent model
        // observation must not require another display event just to see them.
        let verified = ScreenFrame(capturedAt: Date(), captureID: stream)
        capture.frozenFrame = verified
        finishedAt = Date()
        ModelProbe.action = AgentAction(kind: .finish, reason: "Saved note reopened and verified")
        if result == .partialFailure { throw PhoneHarnessFallback(message: "Result not yet verified; inspect the changed screen") }
        let proof: ScreenFrame
        if result == .stale { proof = ScreenFrame(capturedAt: Date().addingTimeInterval(-3), captureID: stream) }
        else if result == .wrongStream { proof = ScreenFrame(capturedAt: Date(), captureID: UUID()) }
        else { proof = verified }
        return PhoneHarnessReceipt(summary: "Verified local result", verifiedFrame: proof,
                                   lastInputCompletedAt: result == .stale ? Date().addingTimeInterval(-4) : inputEnded)
    }
}

@main struct HarnessReuseChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); checks += 1
        }
        for result in [ReceiptHarness.Result.verified, .stale, .wrongStream, .partialFailure] {
            let capture = CaptureService(), executor = MouseExecutor(), stream = UUID()
            capture.frameProvider = { capture.frozenFrame ?? ScreenFrame(captureID: stream) }
            let harness = ReceiptHarness(capture: capture, stream: stream, result: result)
            let engine = AgentEngine(capture: capture, executor: executor)
            engine.phoneHarness = harness
            ModelProbe.calls = 0; ModelProbe.delay = 0
            ModelProbe.action = AgentAction(kind: .phone_tool, text: #"{"operation":"open_search"}"#, reason: "Local workflow")
            executor.onMove = {
                if harness.finishedAt != nil && ModelProbe.calls == 1 { harness.wakeupsBeforeNextObservation += 1 }
                capture.frozenFrame = ScreenFrame(captureID: stream)
            }
            var config = AgentSettings()
            config.startDelay = 0; config.stepInterval = 1; config.maxSteps = 2
            PrivacyConsent.grant(config)
            engine.start(task: "Reuse the locally verified screen", settings: config)
            let deadline = Date().addingTimeInterval(5)
            while !engine.executionSettled && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            PrivacyConsent.revoke()
            expect(engine.executionSettled && engine.phase == .completed, "Workflow must complete after a new model observation")
            expect(ModelProbe.calls == 2, "Macro result must be checked by the model rather than declaring completion locally")
            expect(executor.actions.isEmpty, "Semantic macro must not be replayed as a raw input")
            if result == .verified {
                expect(harness.wakeupsBeforeNextObservation == 0,
                       "Final verified pixels must reach the next model observation without another pointer wake")
                // Model-return validation still requires independent current
                // pixels; the reuse path must not bypass that guard.
                expect(!executor.pointerMoves.isEmpty, "Model-return frame validation remains active after reuse")
            } else {
                expect(harness.wakeupsBeforeNextObservation > 0,
                       "Expired, wrong-stream or partially executed receipts must reacquire a frame")
            }
        }
        print("\(checks) production engine receipt-reuse checks passed; offline frames/model/input only.")
    }
}
