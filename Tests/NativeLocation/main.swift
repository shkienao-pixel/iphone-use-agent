import Foundation

@main struct NativeLocationChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        func started() async {
            for _ in 0..<100 { if CLLocationManager.latest != nil { return }; await Task.yield() }
            preconditionFailure("Reader did not create manager")
        }
        let reader = NativeLocationReader()
        var completed = false
        let pending = Task { @MainActor in defer { completed = true }; return try await reader.read() }
        await started(); let manager = CLLocationManager.latest!
        try await Task.sleep(for: .milliseconds(180))
        expect(!completed && manager.permissionRequests == 1 && manager.locationRequests == 0,
               "Permission review can exceed the acquisition deadline without failing or reading")
        manager.grant(); manager.grant()
        expect(manager.locationRequests == 1, "Grant begins exactly one location acquisition")
        manager.deliver()
        let data = try JSONSerialization.jsonObject(with: Data(try await pending.value.utf8)) as! [String: Any]
        expect(data["approximate"] as? Bool == true && data["continuous_tracking"] as? Bool == false,
               "One real reader result retains approximate noncontinuous semantics")
        expect(manager.stops == 1, "Successful query stops updates")
        manager.deliver(); expect(manager.locationRequests == 1, "Late update cannot start another acquisition")

        CLLocationManager.latest = nil
        let cancelledReader = NativeLocationReader()
        let cancelled = Task { @MainActor in try await cancelledReader.read() }
        await started(); let cancelledManager = CLLocationManager.latest!
        cancelled.cancel()
        if case .failure(let error) = await cancelled.result { expect(error is CancellationError, "Cancel returns cancellation") }
        else { preconditionFailure("Cancelled authorization succeeded") }
        cancelledManager.grant(); cancelledManager.deliver()
        expect(cancelledManager.locationRequests == 0, "Late permission after user cancellation cannot read")

        CLLocationManager.latest = nil
        let timeoutReader = NativeLocationReader()
        let timed = Task { @MainActor in try await timeoutReader.read() }
        await started(); let timeoutManager = CLLocationManager.latest!
        timeoutManager.grant()
        if case .failure(let error) = await timed.result { expect(error.localizedDescription.contains("定位超时"), "Authorized acquisition still times out") }
        else { preconditionFailure("Missing location did not time out") }
        expect(timeoutManager.stops == 1, "Timed out acquisition stops updates")
        timeoutManager.grant(); expect(timeoutManager.locationRequests == 1, "Late grant after timeout cannot restart")

        CLLocationManager.latest = nil
        let deniedReader = NativeLocationReader()
        let denied = Task { @MainActor in try await deniedReader.read() }
        await started(); let deniedManager = CLLocationManager.latest!
        deniedManager.authorizationStatus = .denied
        deniedManager.delegate?.locationManagerDidChangeAuthorization(deniedManager)
        if case .failure(let error) = await denied.result { expect(error.localizedDescription.contains("没有位置访问权限"), "Denial returns a permission error") }
        else { preconditionFailure("Denied query succeeded") }
        expect(deniedManager.locationRequests == 0, "Denied request cannot start updates")
        print("\(checks) actual location-reader permission/deadline/cancellation checks passed; synthetic manager and 80ms acquisition timeout only, no OS permission/device proof.")
    }
}
