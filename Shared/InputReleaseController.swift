import Foundation

/// Transport evidence only. Even an acknowledged write does not certify that
/// the OS received a HID release or that a business action did/did not occur.
struct InputReleaseResult: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case acknowledgedWrite, unconfirmedWrite
        case notSubmittedGenerationChanged, notSubmittedUnavailable
        case notSubmittedWriterBusy, notSubmittedRejected, notSubmittedWaitInterrupted
    }
    var outcome: Outcome
    var submittedToTransport: Bool { outcome == .acknowledgedWrite || outcome == .unconfirmedWrite }
    var attAcknowledged: Bool { outcome == .acknowledgedWrite }
}

/// Cancellation cleanup gets a fresh task, never cancellation authority for an
/// ordinary input. Requests coalesce only while in flight for one generation.
@MainActor final class InputReleaseController {
    struct State: Sendable {
        var generation: UUID
        var transportAvailable: Bool
        var writerBusy: Bool
    }
    private let state: () -> State
    private let submit: (UUID, @escaping @MainActor () -> Void) async throws -> Void
    private let now: () -> Double
    private let pause: () async throws -> Void
    private let waitLimit: Double
    private var pending: (id: UUID, generation: UUID, task: Task<InputReleaseResult, Never>)?

    init(state: @escaping () -> State,
         submit: @escaping (UUID, @escaping @MainActor () -> Void) async throws -> Void,
         now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         pause: @escaping () async throws -> Void = { try await Task.sleep(nanoseconds: 10_000_000) },
         waitLimit: Double = 3) {
        self.state = state; self.submit = submit; self.now = now; self.pause = pause
        self.waitLimit = waitLimit
    }
    @discardableResult func release(expectedGeneration: UUID) async -> InputReleaseResult {
        // Capture/compare before registering work; a caller's old session must
        // never gain permission to clean up a newly connected accessory.
        guard state().generation == expectedGeneration else { return .init(outcome: .notSubmittedGenerationChanged) }
        if let pending, pending.generation == expectedGeneration { return await pending.task.value }
        let id = UUID()
        let task = Task { @MainActor in
            let result = await perform(expectedGeneration: expectedGeneration)
            if pending?.id == id { pending = nil }
            return result
        }
        pending = (id, expectedGeneration, task)
        return await task.value
    }
    private func perform(expectedGeneration: UUID) async -> InputReleaseResult {
        // The former 1s wait could expire before the existing writer's 3s ATT
        // timeout. Only waiting for that writer is bounded here to 3s. A release
        // subsequently submitted retains its own normal 3s ATT deadline; the
        // separate 35s pairing deadline is unchanged. Never clear a live writer.
        let deadline = now() + waitLimit
        while true {
            let current = state()
            guard current.generation == expectedGeneration else { return .init(outcome: .notSubmittedGenerationChanged) }
            guard current.transportAvailable else { return .init(outcome: .notSubmittedUnavailable) }
            if !current.writerBusy { break }
            guard now() < deadline else { return .init(outcome: .notSubmittedWriterBusy) }
            do { try await pause() }
            catch { return .init(outcome: .notSubmittedWaitInterrupted) }
        }
        // submit must independently check this expected generation immediately
        // before its actual transport write, across any executor hop.
        var submitted = false
        do {
            try await submit(expectedGeneration) { submitted = true }
            guard state().generation == expectedGeneration else {
                return .init(outcome: submitted ? .unconfirmedWrite : .notSubmittedGenerationChanged)
            }
            return .init(outcome: submitted ? .acknowledgedWrite : .notSubmittedRejected)
        } catch {
            if submitted { return .init(outcome: .unconfirmedWrite) }
            let current = state()
            if current.generation != expectedGeneration { return .init(outcome: .notSubmittedGenerationChanged) }
            if !current.transportAvailable { return .init(outcome: .notSubmittedUnavailable) }
            if current.writerBusy { return .init(outcome: .notSubmittedWriterBusy) }
            return .init(outcome: .notSubmittedRejected)
        }
    }
}
