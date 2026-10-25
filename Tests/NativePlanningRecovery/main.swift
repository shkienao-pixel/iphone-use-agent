import Foundation

enum FixtureFailure: Error { case denied, invalidResponse, unknownNativeCommit }

@main struct Checks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool) { precondition(value); count += 1 }
        for code in [NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                     NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed] {
            check(NativePlanningRecovery.delay(for: NSError(domain: NSURLErrorDomain, code: code), retries: 0) != nil)
        }
        for code in [NSURLErrorCancelled, NSURLErrorBadURL, NSURLErrorUserAuthenticationRequired,
                     NSURLErrorServerCertificateUntrusted, NSURLErrorAppTransportSecurityRequiresSecureConnection] {
            check(NativePlanningRecovery.delay(for: NSError(domain: NSURLErrorDomain, code: code), retries: 0) == nil)
        }
        for error: Error in [CancellationError(), FixtureFailure.denied, FixtureFailure.invalidResponse,
                             FixtureFailure.unknownNativeCommit, NSError(domain: "HTTP", code: 429),
                             NSError(domain: "HTTP", code: 401), NSError(domain: "HTTP", code: 503),
                             NSError(domain: "UnknownWrite", code: -1009,
                                     userInfo: [NSLocalizedDescriptionKey: "The request timed out."])] {
            check(NativePlanningRecovery.delay(for: error, retries: 0) == nil)
        }
        let network = URLError(.notConnectedToInternet)
        check(NativePlanningRecovery.delay(for: network, retries: -1) == nil)
        check(NativePlanningRecovery.delay(for: network, retries: 8) == nil)
        check(NativePlanningRecovery.delays.count == 8)
        check(NativePlanningRecovery.delays.reduce(0, +) == 149_000_000_000)

        func service(_ status: Int = 503, _ code: String? = nil, after: String? = nil,
                     now: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> NativePlanningServiceFailure? {
            let error: [String: Any] = ["code": code as Any? ?? NSNull(), "message": "PRIVATE_PROVIDER_TEXT_NOT_FOR_LOGS"]
            let data = try! JSONSerialization.data(withJSONObject: ["error": error])
            return NativePlanningServiceFailure.response(status: status, body: data, retryAfter: after, now: now)
        }
        for status in [500, 502, 503, 504] {
            let failure = service(status)!
            check(NativePlanningRecovery.delay(for: failure, retries: 0, jitter: 0) == 2_000_000_000)
            check(!failure.localizedDescription.contains("PRIVATE_PROVIDER_TEXT"))
        }
        for status in [400, 401, 403, 408, 409, 429, 501, 505] { check(service(status) == nil) }
        for code in ["subscription_sharing_usage_limit_exceeded", "subscription_sharing_user_not_eligible",
                     "subscription_sharing_invalid_user", "subscription_sharing_route_not_supported",
                     "subscription_sharing_unsupported_capability", "invalid_grant", "invalid_client", "insufficient_quota",
                     "organization_spend_limit_exceeded", "project_spend_limit_exceeded", "organization_usage_limit_exceeded",
                     "chatpass_v2_scope_not_authorized", "unknown_code"] { check(service(503, code) == nil) }
        for code in ["server_is_overloaded", "server_error", "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable"] {
            check(service(503, code) != nil)
        }
        check(NativePlanningServiceFailure.response(status: 503, body: Data("<html>unavailable</html>".utf8), retryAfter: nil) != nil)
        check(NativePlanningServiceFailure.response(status: 503, body: Data("{\"error\":{\"code\":42}}".utf8), retryAfter: nil) == nil)
        check(NativePlanningServiceFailure.response(status: 503, body: Data(repeating: 32, count: 1_000_001), retryAfter: nil) == nil)
        check(NativePlanningRecovery.delay(for: service(after: "120")!, retries: 0, jitter: 0) == 120_000_000_000)
        check(NativePlanningRecovery.delay(for: service(after: " 2.25 ")!, retries: 0, jitter: 0) == 2_250_000_000)
        check(NativePlanningRecovery.delay(for: service(after: "0")!, retries: 2, jitter: 0) == 8_000_000_000)
        check(NativePlanningRecovery.delay(for: service(after: "invalid")!, retries: 0, jitter: 0) == 2_000_000_000)
        check(NativePlanningRecovery.delay(for: service(after: "301")!, retries: 0, jitter: 0) == nil)
        check(NativePlanningRecovery.delay(for: service(after: String(repeating: "9", count: 400))!, retries: 0, jitter: 0) == nil)
        check(NativePlanningRecovery.delay(for: service(after: "300")!, retries: 0, jitter: 1) == 300_000_000_000)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        check(NativePlanningRecovery.delay(for: service(after: formatter.string(from: now.addingTimeInterval(120)))!, retries: 0, jitter: 0) == 120_000_000_000)
        check(NativePlanningRecovery.delay(for: service(after: formatter.string(from: now.addingTimeInterval(-120)))!, retries: 0, jitter: 0) == 2_000_000_000)
        check(NativePlanningRecovery.delay(for: service()!, retries: 0, jitter: 1) == 3_000_000_000)
        check(NativePlanningRecovery.delay(for: service()!, retries: 8, jitter: 0) == nil)

        var attempts = 0, waits = 0, retries = 0, nativeDispatches = 0
        let action = try await NativePlanningRecovery.nextAction(
            stillCurrent: {}, request: {
                attempts += 1
                if attempts <= 2 { throw network }
                return "one_native_action"
            }, wait: { _ in waits += 1 }, onRetry: { _, _ in retries += 1 })
        if action == "one_native_action" { nativeDispatches += 1 }
        check(attempts == 3); check(waits == 2); check(retries == 2); check(nativeDispatches == 1)

        attempts = 0; waits = 0; nativeDispatches = 0
        let recovered = try await NativePlanningRecovery.nextAction(stillCurrent: {}, request: {
            attempts += 1
            if attempts == 1 { throw service(503, "subscription_sharing_usage_unavailable", after: "120")! }
            return "one_native_action"
        }, wait: { interval in check(interval >= 120_000_000_000); waits += 1 }, onRetry: { _, _ in })
        if recovered == "one_native_action" { nativeDispatches += 1 }
        check(attempts == 2); check(waits == 1); check(nativeDispatches == 1)

        attempts = 0; waits = 0
        do {
            let _: String = try await NativePlanningRecovery.nextAction(stillCurrent: {}, request: {
                attempts += 1; throw service(503, after: "301")!
            }, wait: { _ in waits += 1 }, onRetry: { _, _ in })
            preconditionFailure("Long server delay ignored")
        } catch is NativePlanningServiceFailure {}
        check(attempts == 1); check(waits == 0)

        attempts = 0; waits = 0
        do {
            let _: String = try await NativePlanningRecovery.nextAction(stillCurrent: {}, request: {
                attempts += 1; throw service(503, "server_is_overloaded")!
            }, wait: { _ in waits += 1 }, onRetry: { _, _ in })
            preconditionFailure("Server failure exceeded retry budget")
        } catch is NativePlanningServiceFailure {}
        check(attempts == 9); check(waits == 8)

        attempts = 0; waits = 0
        do {
            let _: String = try await NativePlanningRecovery.nextAction(
                stillCurrent: {}, request: { attempts += 1; throw network },
                wait: { _ in waits += 1 }, onRetry: { _, _ in })
            preconditionFailure("Exhausted retry budget returned an action")
        } catch let error as URLError { check(error.code == .notConnectedToInternet) }
        check(attempts == 9); check(waits == 8)

        for failure in [FixtureFailure.denied, .invalidResponse, .unknownNativeCommit] {
            attempts = 0; waits = 0
            do {
                let _: String = try await NativePlanningRecovery.nextAction(
                    stillCurrent: {}, request: { attempts += 1; throw failure },
                    wait: { _ in waits += 1 }, onRetry: { _, _ in })
                preconditionFailure("Non-transport failure returned an action")
            } catch is FixtureFailure {}
            check(attempts == 1); check(waits == 0)
        }

        var current = true
        attempts = 0
        do {
            let _: String = try await NativePlanningRecovery.nextAction(
                stillCurrent: { if !current { throw CancellationError() } },
                request: { attempts += 1; throw network },
                wait: { _ in current = false }, onRetry: { _, _ in })
            preconditionFailure("Stopped task issued another request")
        } catch is CancellationError {}
        check(attempts == 1)

        current = true; attempts = 0; waits = 0
        do {
            let _: String = try await NativePlanningRecovery.nextAction(
                stillCurrent: { if !current { throw CancellationError() } },
                request: { attempts += 1; current = false; return "late_action" },
                wait: { _ in waits += 1 }, onRetry: { _, _ in })
            preconditionFailure("Late response escaped the stopped-task guard")
        } catch is CancellationError {}
        check(attempts == 1); check(waits == 0)

        var waitEntered = false
        attempts = 0
        let task = Task { @MainActor in
            let _: String = try await NativePlanningRecovery.nextAction(
                stillCurrent: {}, request: { attempts += 1; throw network },
                wait: { _ in waitEntered = true; try await Task.sleep(nanoseconds: 5_000_000_000) },
                onRetry: { _, _ in })
        }
        for _ in 0..<100 where !waitEntered { try await Task.sleep(nanoseconds: 2_000_000) }
        check(waitEntered)
        let cancelledAt = Date()
        task.cancel()
        do { try await task.value; preconditionFailure("Cancellation returned success") }
        catch is CancellationError {}
        check(Date().timeIntervalSince(cancelledAt) < 2)
        check(attempts == 1)

        attempts = 0
        var serverWaitEntered = false
        let serverTask = Task { @MainActor in
            let _: String = try await NativePlanningRecovery.nextAction(stillCurrent: {}, request: {
                attempts += 1; throw service(503, "server_is_overloaded", after: "120")!
            }, wait: { interval in serverWaitEntered = true; try await Task.sleep(nanoseconds: interval) }, onRetry: { _, _ in })
        }
        for _ in 0..<100 where !serverWaitEntered { try await Task.sleep(nanoseconds: 2_000_000) }
        check(serverWaitEntered)
        let serverCancelledAt = Date(); serverTask.cancel()
        do { try await serverTask.value; preconditionFailure("Cancelled server wait returned an action") }
        catch is CancellationError {}
        check(Date().timeIntervalSince(serverCancelledAt) < 2); check(attempts == 1)

        attempts = 0; nativeDispatches = 0
        let _: String = try await NativePlanningRecovery.nextAction(
            stillCurrent: {}, request: { attempts += 1; return "write" },
            wait: { _ in preconditionFailure("Successful model call waited") }, onRetry: { _, _ in })
        do { nativeDispatches += 1; throw FixtureFailure.unknownNativeCommit }
        catch is FixtureFailure {}
        check(attempts == 1); check(nativeDispatches == 1)
        print("Native planning recovery: \(count) actual production-policy checks passed; injected requests/waits only, no device or network")
    }
}
