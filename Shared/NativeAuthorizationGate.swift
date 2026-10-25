import Foundation

/// Cancels the caller's wait even when a system permission API cannot cancel.
/// A late OS callback is ignored; callers must check cancellation before reading.
@MainActor final class NativeAuthorizationGate {
    enum GateError: Error { case alreadyUsed }
    private var used = false
    private var continuation: CheckedContinuation<Void, Error>?

    func wait(start: (@escaping @MainActor (Result<Void, Error>) -> Void) -> Void) async throws {
        guard !used else { throw GateError.alreadyUsed }
        used = true
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (value: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { value.resume(throwing: CancellationError()); return }
                continuation = value
                start { [weak self] result in self?.finish(result) }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) } })
        try Task.checkCancellation()
    }
    private func finish(_ result: Result<Void, Error>) {
        guard let value = continuation else { return }
        continuation = nil
        value.resume(with: result)
    }
}
