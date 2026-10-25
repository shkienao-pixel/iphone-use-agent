import Foundation

enum AgentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}

/// Synthetic lower I/O only: this is not CoreBluetooth, ATT or a HID oracle.
@MainActor final class BLETransport {
    enum Operation { case release }
    struct Submission {
        let token: UUID
        let generation: UUID
        let expectedGeneration: UUID?
        let cancelledContext: Bool
    }
    var connectionGeneration = UUID()
    var capturedManualGenerations: [UUID] = []
    var pointerConnectionGeneration: UUID {
        capturedManualGenerations.append(connectionGeneration)
        return connectionGeneration
    }
    var connected = true
    var peer: UUID? = UUID()
    var command: UUID? = UUID()
    private var writerValue: UUID?
    var writerStateReads = 0
    var writer: UUID? {
        get { writerStateReads += 1; return writerValue }
        set { writerValue = newValue }
    }
    var autoAcknowledge = false
    var submissions: [Submission] = []
    private var pending: (token: UUID, continuation: CheckedContinuation<Void, Error>)?
    var teardownCalls = 0

    func send(_ op: Operation, expectedConnection: UUID? = nil,
              onSubmitted: (@MainActor () -> Void)? = nil) async throws {
        try Task.checkCancellation()
        guard expectedConnection == nil || expectedConnection == connectionGeneration,
              connected, peer != nil, command != nil, writer == nil else {
            throw AgentError.message("synthetic lower I/O rejected")
        }
        let token = UUID()
        writer = token
        submissions.append(.init(token: token, generation: connectionGeneration,
            expectedGeneration: expectedConnection, cancelledContext: Task.isCancelled))
        onSubmitted?()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pending = (token, continuation)
            if autoAcknowledge {
                Task { @MainActor in await Task.yield(); acknowledge(token: token) }
            }
        }
    }
    func acknowledge(token: UUID? = nil, error: Error? = nil) {
        guard let current = pending, token == nil || token == current.token,
              writerValue == current.token else { return }
        pending = nil; writerValue = nil
        if let error { current.continuation.resume(throwing: error) }
        else { current.continuation.resume() }
    }
    func beginForeignWriter() -> UUID {
        precondition(writerValue == nil && pending == nil)
        let token = UUID(); writerValue = token; return token
    }
    func finishForeignWriter(_ token: UUID) {
        guard pending == nil, writerValue == token else { return }
        writerValue = nil
    }
    func changeConnection() {
        let old = pending; pending = nil; writerValue = nil
        connectionGeneration = UUID(); peer = UUID(); command = UUID(); connected = true
        old?.continuation.resume(throwing: AgentError.message("synthetic connection changed"))
    }
    /// Test teardown only. Clearing a foreign writer here is never a production
    /// behavior/assertion; all ownership assertions occur before case teardown.
    func finishSyntheticIOForTeardown() {
        teardownCalls += 1
        autoAcknowledge = true
        if pending != nil { acknowledge() }
        else { writerValue = nil }
    }
    // EXACT_PRODUCTION_BLE_MEMBERS
}

@MainActor final class SyntheticExecutor { var calibrationInProgress = false }
struct SyntheticRunningRecord { let id: UUID }
@MainActor final class SyntheticEngine {
    var running = false, releasing = false, hasCurrentTask = false
    var currentRecord: SyntheticRunningRecord?
    var pauseCalls = 0, handoffCalls = 0, stopCalls = 0
    func pause() { pauseCalls += 1; running = false }
    func handoff() { handoffCalls += 1; running = false }
    func stop() { stopCalls += 1; running = false }
}
@MainActor final class SyntheticInvalidation {
    var calls = 0
    func invalidate() { calls += 1 }
    func invalidatePreparations() { calls += 1 }
}
@MainActor final class SyntheticStopper {
    struct HandoffReport { let text: String; let messageID: UUID; let conversationID: UUID }
    var handoffReports: [HandoffReport] = []
    var stopCalls = 0, cancelCalls = 0
    func stop() { stopCalls += 1 }
    func cancel() { cancelCalls += 1 }
    func reportTaskHandoff(text: String, to messageID: UUID, in conversationID: UUID) {
        handoffReports.append(.init(text: text, messageID: messageID, conversationID: conversationID))
    }
}

// EXACT_PRODUCTION_SUBMISSION_TYPE

/// Complete extracted methods with explicit opaque dependency doubles.
/// This is not PhoneAgentViewModel and does not construct any app services.
@MainActor final class ExtractedManualOwnerScaffold {
    let ble = BLETransport()
    let executor = SyntheticExecutor()
    let engine = SyntheticEngine()
    let contentStore = SyntheticInvalidation(), assistiveTouchVerification = SyntheticInvalidation()
    let liveCamera = SyntheticStopper(), camera = SyntheticStopper()
    let speech = SyntheticStopper(), conversation = SyntheticStopper()
    struct SyntheticWorkflowServices { var blocksGUI = false }
    var workflowServices = SyntheticWorkflowServices()
    var preparingAutomatically = false, queueRunning = false, queueSwitching = false
    var voicePending = false, calibrating = false
    var manualBusy = false, manualContinuationRequired = false, manualScreenWorkflow = false
    var manual: Task<Void, Never>?, voicePreparation: Task<Void, Never>?
    var recordingAudioOwner: UUID?, voiceMode: String?
    var pendingConsentStart = false
    var pendingConversationTask: ConversationTaskSubmission?, pendingConsentConversationTask: ConversationTaskSubmission?
    var pendingConsentAttachments: [String] = []
    var voiceGeneration = UUID()
    var cancelCalibration: (() -> Void)?
    var notice = ""
    var haltQueueMessages: [String] = []
    var cancelAutomaticPreparationCalls = 0
    func haltQueue(_ message: String) { haltQueueMessages.append(message); queueRunning = false }
    func cancelAutomaticPreparation() {
        cancelAutomaticPreparationCalls += 1
        preparingAutomatically = false
    }
    func snapshot() -> [String: Any] {
        ["manualBusy": manualBusy, "manualExists": manual != nil,
         "manualScreenWorkflow": manualScreenWorkflow, "manualContinuationRequired": manualContinuationRequired,
         "notice": notice, "releaseSubmissionCount": ble.submissions.count,
         "queueHaltCalls": haltQueueMessages.count, "enginePauseCalls": engine.pauseCalls,
         "engineHandoffCalls": engine.handoffCalls, "engineStopCalls": engine.stopCalls]
    }
    // EXACT_PRODUCTION_VM_MEMBERS
}
