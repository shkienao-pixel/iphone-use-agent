import Foundation

/// Pixel comparison is a rejection guard, never evidence of page/target identity.
/// A small popup can occupy <1% of a screen and escape a whole-screen average.
enum FrameChangeAnalysis {
    struct Result {
        let globalDifference: Double
        let largestChangedRegion: Int
        let targetChangedPixels: Int
        var requiresReobservation: Bool {
            globalDifference > 0.18 || largestChangedRegion >= 24 || targetChangedPixels >= 10
        }
    }

    static func compare(_ before: [UInt8], _ after: [UInt8], width: Int, height: Int,
                        targetX: Double? = nil, targetY: Double? = nil) -> Result {
        guard width > 0, height > 0, before.count == width * height * 4,
              after.count == before.count else {
            return Result(globalDifference: 1, largestChangedRegion: Int.max, targetChangedPixels: Int.max)
        }
        var changed = [Bool](repeating: false, count: width * height)
        var sum = 0.0, targetCount = 0
        for index in changed.indices {
            let offset = index * 4
            let delta = (0..<3).map { abs(Double(before[offset + $0]) - Double(after[offset + $0])) }.reduce(0, +) / (3 * 255)
            sum += delta
            changed[index] = delta > 0.16
            if changed[index], let x = targetX, let y = targetY,
               x.isFinite, y.isFinite,
               abs((Double(index % width) + 0.5) / Double(width) - x) <= 0.08,
               abs((Double(index / width) + 0.5) / Double(height) - y) <= 0.04 {
                targetCount += 1
            }
        }
        // Eight-neighbour components preserve thin button/text changes. Tiny
        // isolated cursor/clock changes remain below the conservative cutoff.
        var largest = 0
        for index in changed.indices where changed[index] {
            var queue = [index], head = 0; changed[index] = false
            while head < queue.count {
                let current = queue[head]; head += 1
                let x = current % width, y = current / width
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                    let next = ny * width + nx
                    if changed[next] { changed[next] = false; queue.append(next) }
                }}
            }
            largest = max(largest, queue.count)
        }
        return Result(globalDifference: sum / Double(width * height), largestChangedRegion: largest,
                      targetChangedPixels: targetCount)
    }
}

/// Main-actor, cancellable notification gate. Waiting never creates/retimes a frame.
/// The caller must still validate capture identity, dimensions, pixels and target.
@MainActor final class FrameReadinessGate {
    private struct Waiter {
        let after: Date
        let continuation: CheckedContinuation<Bool, Error>
        let timeout: Task<Void, Never>
    }
    private var waiters: [UUID: Waiter] = [:]
    private var confirmedAt: Date?
    private var available = false

    func update(confirmedAt: Date?, available: Bool) {
        self.confirmedAt = confirmedAt; self.available = available
        for (id, waiter) in waiters {
            if !available { finish(id, result: .success(false)) }
            else if let confirmedAt, confirmedAt > waiter.after,
                    (0..<1.5).contains(Date().timeIntervalSince(confirmedAt)) {
                finish(id, result: .success(true))
            }
        }
    }

    func wait(after: Date, timeout seconds: Double) async throws -> Bool {
        try Task.checkCancellation()
        guard available, seconds.isFinite, seconds > 0 else { return false }
        if let confirmedAt, confirmedAt > after,
           (0..<1.5).contains(Date().timeIntervalSince(confirmedAt)) { return true }
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(min(6, seconds) * 1_000_000_000)) }
                    catch { return }
                    self?.finish(id, result: .success(false))
                }
                waiters[id] = Waiter(after: after, continuation: continuation, timeout: timeout)
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.finish(id, result: .failure(CancellationError())) } })
    }

    private func finish(_ id: UUID, result: Result<Bool, Error>) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel(); waiter.continuation.resume(with: result)
    }
}
