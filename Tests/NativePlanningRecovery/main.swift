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

        var attempts = 0, waits = 0, retries = 0, nativeDispatches = 0
        let action = try await NativePlanningRecovery.nextAction(
            stillCurrent: {}, request: {
                attempts += 1
                if attempts <= 2 { throw network }
                return "one_native_action"
            }, wait: { _ in waits += 1 }, onRetry: { _, _ in retries += 1 })
        if action == "one_native_action" { nativeDispatches += 1 }
        check(attempts == 3); check(waits == 2); check(retries == 2); check(nativeDispatches == 1)

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
