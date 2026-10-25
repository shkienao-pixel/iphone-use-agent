import Foundation

/// Only a failed model HTTP response can create this retry signal. Raw provider
/// text, credentials and request bodies never become diagnostics or log fields.
struct NativePlanningServiceFailure: LocalizedError {
    let status: Int
    let minimumWaitSeconds: Double?
    private let serverWaitExceedsBudget: Bool
    static let maximumServerWaitSeconds: Double = 300

    static func response(status: Int, body: Data, retryAfter: String?, now: Date = Date()) -> Self? {
        guard [500, 502, 503, 504].contains(status), body.count <= 1_000_000 else { return nil }
        let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = root?["error"] as? [String: Any]
        for key in ["code", "type"] {
            if let value = error?[key], !(value is NSNull), !(value is String) { return nil }
        }
        let code = error?["code"] as? String ?? error?["type"] as? String
        let retryableCodes: Set<String> = ["server_error", "internal_error", "internal_server_error", "service_unavailable_error",
            "server_is_overloaded", "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable"]
        if let code, !code.isEmpty, !retryableCodes.contains(code) { return nil }
        let wait = retryAfterSeconds(retryAfter, now: now)
        return Self(status: status, minimumWaitSeconds: wait,
                    serverWaitExceedsBudget: wait.map { !$0.isFinite || $0 > maximumServerWaitSeconds } ?? false)
    }

    private static func retryAfterSeconds(_ header: String?, now: Date) -> Double? {
        guard let value = header?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil {
            return Double(value) ?? .infinity
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"; formatter.isLenient = false
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }

    func delay(base: UInt64, jitter: Double) -> UInt64? {
        guard !serverWaitExceedsBudget else { return nil }
        let seconds = max(Double(base) / 1_000_000_000, minimumWaitSeconds ?? 0)
        let extra = jitter.isFinite ? min(1, max(0, jitter)) : 0
        let bounded = min(Self.maximumServerWaitSeconds, seconds + extra)
        return UInt64(ceil(bounded * 1_000_000_000))
    }

    var errorDescription: String? {
        serverWaitExceedsBudget
            ? "模型服务要求较长等待，已保留原任务进度；本次未自动重试，也未采用动作。（HTTP \(status)）"
            : "模型服务暂不可用，已完成结果保留；本次未采用动作。（HTTP \(status)）"
    }
}

/// Retries only the model planning request, before any returned action is dispatched.
enum NativePlanningRecovery {
    static let delays: [UInt64] = [2, 4, 8, 15, 30, 30, 30, 30].map { $0 * 1_000_000_000 }

    static func delay(for error: Error, retries: Int, jitter: Double = Double.random(in: 0...1)) -> UInt64? {
        guard retries >= 0, retries < delays.count, !(error is CancellationError) else { return nil }
        if let failure = error as? NativePlanningServiceFailure { return failure.delay(base: delays[retries], jitter: jitter) }
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
