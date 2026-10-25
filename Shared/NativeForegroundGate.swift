import Foundation

/// Wait before dispatch, without retrying an operation or restoring a task.
/// iOS may suspend this wait; returning to the foreground only releases the
/// still-live, uncancelled caller. A stopped caller never dispatches later.
@MainActor enum NativeForegroundGate {
    static func waitUntilActive(
        isActive: @MainActor () -> Bool,
        wait: @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) }
    ) async throws {
        try Task.checkCancellation()
        while !isActive() {
            try Task.checkCancellation()
            try await wait()
        }
        try Task.checkCancellation()
    }
}
