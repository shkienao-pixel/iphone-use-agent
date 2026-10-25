import Foundation

@main struct Checks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label); checks += 1
        }
        let w = 96, h = 192
        let blank = [UInt8](repeating: 255, count: w * h * 4)
        func patch(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> [UInt8] {
            var image = blank
            for row in y..<(y + height) { for column in x..<(x + width) {
                for c in 0..<3 { image[(row * w + column) * 4 + c] = 0 }
            }}
            return image
        }
        check(!FrameChangeAnalysis.compare(blank, blank, width: w, height: h).requiresReobservation, "unchanged")
        let popup = FrameChangeAnalysis.compare(blank, patch(40, 75, 12, 6), width: w, height: h)
        check(popup.globalDifference < 0.01 && popup.requiresReobservation, "small modal cannot hide in global average")
        check(!FrameChangeAnalysis.compare(blank, patch(20, 20, 2, 2), width: w, height: h).requiresReobservation, "tiny cursor noise")
        check(FrameChangeAnalysis.compare(blank, patch(44, 95, 5, 2), width: w, height: h,
            targetX: 0.48, targetY: 0.5).requiresReobservation, "changed target text")
        check(!FrameChangeAnalysis.compare(blank, patch(44, 95, 5, 2), width: w, height: h,
            targetX: 0.1, targetY: 0.1).requiresReobservation, "isolated tiny non-target change")
        check(FrameChangeAnalysis.compare([], blank, width: w, height: h).requiresReobservation, "bad raster fails closed")
        let gate = FrameReadinessGate(), start = Date()
        gate.update(confirmedAt: start, available: true)
        let waiter = Task { @MainActor in try await gate.wait(after: start, timeout: 2) }
        await Task.yield()
        let began = ContinuousClock.now
        gate.update(confirmedAt: Date(), available: true)
        let ready = try await waiter.value
        check(ready && began.duration(to: .now) < .milliseconds(200), "actual event wakes before timeout")
        gate.update(confirmedAt: start.addingTimeInterval(-5), available: true)
        let stale = try await gate.wait(after: start, timeout: 0.02)
        check(!stale, "old pixels/time not fabricated")
        gate.update(confirmedAt: start.addingTimeInterval(5), available: true)
        let future = try await gate.wait(after: start, timeout: 0.02)
        check(!future, "future confirmation rejected")
        gate.update(confirmedAt: nil, available: true)
        let cancelled = Task { @MainActor in try await gate.wait(after: start, timeout: 2) }
        await Task.yield(); cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("cancel must throw") }
        catch is CancellationError { checks += 1 }
        let stopped = Task { @MainActor in try await gate.wait(after: start, timeout: 2) }
        await Task.yield(); gate.update(confirmedAt: nil, available: false)
        let stopResult = try await stopped.value
        check(!stopResult, "shared stream stopped wakes waiter")
        let unavailable = try await gate.wait(after: start, timeout: 2)
        check(!unavailable, "unavailable source does not wait or certify readiness")
        gate.update(confirmedAt: nil, available: true)
        let a = Task { @MainActor in try await gate.wait(after: start, timeout: 1) }
        let b = Task { @MainActor in try await gate.wait(after: start, timeout: 1) }
        await Task.yield(); gate.update(confirmedAt: Date(), available: true)
        let results = try await (a.value, b.value)
        check(results.0 && results.1, "multiple waiters resume exactly once")
        print("PASS: \(checks) production frame-change and event-wait checks (offline)")
    }
}
