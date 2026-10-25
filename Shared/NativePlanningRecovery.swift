import Foundation

/// Retries only the model planning request, before any returned action is dispatched.
enum NativePlanningRecovery {
    static let delays: [UInt64] = [2, 4, 8, 15, 30, 30, 30, 30].map { $0 * 1_000_000_000 }

    static func delay(for error: Error, retries: Int) -> UInt64? {
        guard retries >= 0, retries < delays.count, !(error is CancellationError) else { return nil }
        let value = error as NSError
        guard value.domain == NSURLErrorDomain,
              [NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
               NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed].contains(value.code)
        else { return nil }
        return delays[retries]
    }

    @MainActor static func nextAction<Value>(
        stillCurrent: () throws -> Void,
        request: () async throws -> Value,
        wait: (UInt64) async throws -> Void,
        onRetry: (Int, UInt64) -> Void
    ) async throws -> Value {
        var retries = 0
        while true {
            try Task.checkCancellation()
            try stillCurrent()
            do {
                let value = try await request()
                try Task.checkCancellation()
                try stillCurrent()
                return value
            } catch {
                try Task.checkCancellation()
                try stillCurrent()
                guard let interval = delay(for: error, retries: retries) else { throw error }
                retries += 1
                onRetry(retries, interval)
                try stillCurrent()
                try await wait(interval)
                try Task.checkCancellation()
                try stillCurrent()
            }
        }
    }
}
