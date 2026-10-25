import Foundation

@main struct NativeAuthorizationChecks {
    enum FixtureError: Error { case systemFailure }
    @MainActor static func main() async throws {
        var checks = 0
        let immediate = NativeAuthorizationGate()
        try await immediate.wait { complete in complete(.success(())); complete(.failure(FixtureError.systemFailure)) }
        checks += 1
        do { try await immediate.wait { _ in fatalError("Gate reused") }; fatalError("Reuse accepted") }
        catch NativeAuthorizationGate.GateError.alreadyUsed { checks += 1 }
        do {
            try await NativeAuthorizationGate().wait { complete in complete(.failure(FixtureError.systemFailure)) }
            fatalError("OS failure ignored")
        } catch FixtureError.systemFailure { checks += 1 }
        var started = false
        let cancelledBeforeStart = Task { @MainActor in
            try await NativeAuthorizationGate().wait { _ in started = true }
        }
        cancelledBeforeStart.cancel()
        if case .failure(let error) = await cancelledBeforeStart.result { precondition(error is CancellationError); checks += 1 }
        else { fatalError("Pre-cancelled request succeeded") }
        precondition(!started); checks += 1
        var complete: (@MainActor (Result<Void, Error>) -> Void)?
        var readAfterAuthorization = false
        let pending = Task { @MainActor in
            try await NativeAuthorizationGate().wait { complete = $0 }
            readAfterAuthorization = true
        }
        for _ in 0..<1000 { if complete != nil { break }; await Task.yield() }
        precondition(complete != nil); checks += 1
        pending.cancel()
        if case .failure(let error) = await pending.result { precondition(error is CancellationError); checks += 1 }
        else { fatalError("Cancellation did not settle without an OS callback") }
        complete?(.success(())); complete?(.failure(FixtureError.systemFailure))
        for _ in 0..<10 { await Task.yield() }
        precondition(!readAfterAuthorization); checks += 1
        var racingComplete: (@MainActor (Result<Void, Error>) -> Void)?
        let racing = Task { @MainActor in
            try await NativeAuthorizationGate().wait { racingComplete = $0 }
        }
        for _ in 0..<1000 { if racingComplete != nil { break }; await Task.yield() }
        precondition(racingComplete != nil)
        racingComplete?(.success(())); racing.cancel()
        if case .failure(let error) = await racing.result { precondition(error is CancellationError); checks += 1 }
        else { fatalError("Success/cancel race bypassed post-wait cancellation check") }
        var active = false
        var enteredForegroundWait = false
        var nativeDispatches = 0
        let background = Task { @MainActor in
            try await NativeForegroundGate.waitUntilActive(isActive: { active }, wait: {
                enteredForegroundWait = true
                try await Task.sleep(for: .milliseconds(5))
            })
            nativeDispatches += 1
        }
        for _ in 0..<1000 { if enteredForegroundWait { break }; await Task.yield() }
        precondition(enteredForegroundWait && nativeDispatches == 0); checks += 1
        active = true
        try await background.value
        precondition(nativeDispatches == 1); checks += 1

        active = false; enteredForegroundWait = false
        let stoppedBackground = Task { @MainActor in
            try await NativeForegroundGate.waitUntilActive(isActive: { active }, wait: {
                enteredForegroundWait = true
                try await Task.sleep(for: .seconds(60))
            })
            nativeDispatches += 1
        }
        for _ in 0..<1000 { if enteredForegroundWait { break }; await Task.yield() }
        precondition(enteredForegroundWait); checks += 1
        stoppedBackground.cancel()
        if case .failure(let error) = await stoppedBackground.result { precondition(error is CancellationError); checks += 1 }
        else { fatalError("Background wait did not cancel") }
        active = true
        for _ in 0..<10 { await Task.yield() }
        precondition(nativeDispatches == 1); checks += 1

        let alreadyStopped = Task { @MainActor in
            try await NativeForegroundGate.waitUntilActive(isActive: { true })
            nativeDispatches += 1
        }
        alreadyStopped.cancel()
        if case .failure(let error) = await alreadyStopped.result { precondition(error is CancellationError); checks += 1 }
        else { fatalError("Pre-cancelled foreground request dispatched") }
        precondition(nativeDispatches == 1); checks += 1

        active = false
        do {
            try await NativeForegroundGate.waitUntilActive(isActive: { active }, wait: { throw FixtureError.systemFailure })
            fatalError("Foreground wait failure ignored")
        } catch FixtureError.systemFailure { checks += 1 }
        let cancelOnForeground = Task { @MainActor in
            try await NativeForegroundGate.waitUntilActive(isActive: { active }, wait: {
                active = true
                withUnsafeCurrentTask { $0?.cancel() }
            })
            nativeDispatches += 1
        }
        if case .failure(let error) = await cancelOnForeground.result { precondition(error is CancellationError); checks += 1 }
        else { fatalError("Late foreground event bypassed cancellation") }
        precondition(nativeDispatches == 1); checks += 1
        print("\(checks) production native authorization/foreground cancellation checks passed. State and OS callbacks are injected; no permission/device acceptance.")
    }
}
