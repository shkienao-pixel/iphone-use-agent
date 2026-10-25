import Foundation

@MainActor private final class ReadingClock { var now: TimeInterval = 0 }

/// Virtual monotonic time exercises the real collector, navigation, checkpoints
/// and stores. Advancing this clock does not prove two-hour hardware stability.
@MainActor enum XHSLongReadingChecks {
    static func run(folder: URL) async throws -> Int {
        var checks = 0
        func expect(_ value: Bool, _ message: String) { precondition(value,message); checks += 1 }
        func task(_ id: String, seconds: Double = 7200) -> XiaohongshuCollectionTask {
            var value = XiaohongshuCollectionTask(id:id,keyword:"人工智能",sampleSize:2)
            value.stops.maxSeconds = seconds
            return value
        }
        func store(_ id: String) -> XiaohongshuCollectionStore {
            .init(url:folder.appendingPathComponent(id+".json"))
        }
        let configured = task("two-hour-budget")
        try configured.validate()
        let roundtrip = try JSONDecoder().decode(XiaohongshuCollectionTask.self,from:JSONEncoder().encode(configured))
        expect(roundtrip.stops.maxSeconds == 7200 && XiaohongshuCollectionStops().maxSeconds == 120, "Explicit two hours round-trip without enlarging the default short task")
        for seconds in [7200.1,Double.infinity,Double.nan] {
            var rejected = false
            do { try task("invalid-duration",seconds:seconds).validate() } catch { rejected = true }
            expect(rejected, "Unsupported/nonfinite reading budget is rejected")
        }

        for seconds in [120.0,7200.0] {
            let timer = ReadingClock(), replay = XHSReplay([[.init(id:"0123456789abcdef01234567")]])
            replay.onRead = { _ in timer.now = seconds + 5 }
            let value = try await XiaohongshuCollector(store:store("late-frame-"+String(Int(seconds))),clock:{timer.now})
                .collect(task:task("late-frame-"+String(Int(seconds)),seconds:seconds),driver:replay)
            expect(value.status == .boundedStop && value.stopReason == "max_seconds" && replay.opens == 0,
                "A frame delivered after budget expiry cannot start new input")
            expect(value.checkpoint?.elapsedSeconds == seconds + 5, "In-flight observation overrun remains visible rather than clamped away")
        }

        let timer = ReadingClock(), pausedStore = store("paused-budget"), plan = task("paused-budget")
        let first = XHSReplay([[]]); first.onRead = { _ in timer.now = 3600 }
        let paused = try await XiaohongshuCollector(store:pausedStore,clock:{timer.now}).collect(task:plan,driver:first)
        expect(paused.status == .paused && paused.checkpoint?.elapsedSeconds == 3600, "A missing target pauses with half of the two-hour budget durably consumed")
        timer.now = 1_000_000 // Offline/pause gap: the next call starts a new monotonic segment.
        let next = XHSReplay([[.init(id:"0123456789abcdef01234567"),.init(id:"1123456789abcdef01234567")]])
        next.onOpen = { timer.now = 1_003_599 }
        next.onRead = { count in if count == 3 { timer.now = 1_003_600 } }
        let resumed = try await XiaohongshuCollector(store:pausedStore,clock:{timer.now}).collect(task:plan,driver:next)
        expect(resumed.status == .boundedStop && resumed.stopReason == "max_seconds" && resumed.notes.count == 1,
            "Resume preserves earlier budget and saved notes instead of granting another two hours")
        expect(next.opens == 1 && resumed.checkpoint?.elapsedSeconds == 7200, "Only remaining execution time is consumed; second note is never opened after expiry")
        let persisted = try pausedStore.run(id:plan.id)!
        expect(persisted.checkpoint?.elapsedSeconds == 7200 && persisted.notes.count == 1, "Time and source-ID progress survive reopening storage")
        expect(persisted.readingBudgetReceipt.contains("剩余 0.0 秒") && persisted.readingBudgetReceipt.contains("不等同有效阅读时长"),
            "The host receipt exposes the exhausted remainder and never labels runtime as effective reading time")
        timer.now = 2_000_000
        let exhaustedReplay = XHSReplay([[.init(id:"1123456789abcdef01234567")]])
        let exhausted = try await XiaohongshuCollector(store:pausedStore,clock:{timer.now}).collect(task:plan,driver:exhaustedReplay)
        expect(exhausted.stopReason == "max_seconds" && exhaustedReplay.reads == 0 && exhaustedReplay.opens == 0,
            "An exhausted task cannot reset its budget by another invocation")

        let nestedClock = ReadingClock(), native = XHSNativeReplay()
        native.onShare = { nestedClock.now = 7200 }
        let nested = try await XiaohongshuCollector(store:store("nested-budget"),clock:{nestedClock.now})
            .collect(task:task("nested-budget"),driver:native)
        expect(nested.status == .boundedStop && nested.stopReason == "max_seconds", "Budget expiry propagates out of the nested share workflow as a bounded stop")
        expect(native.shareTaps == 1 && native.copyTaps == 0 && native.closeTaps == 0,
            "Every nested input checks budget: no Copy or Close starts after Share exhausts time")
        expect(nested.notes.isEmpty && !nested.pending.isEmpty && nested.sourceAttempts.contains { $0.stage == .uncertain },
            "Interrupted source evidence remains pending, never promoted to a completed note")
        return checks
    }
}
