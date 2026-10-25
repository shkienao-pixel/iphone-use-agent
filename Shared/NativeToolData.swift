import Foundation

enum NativeToolData {
    // Health sources can overlap (for example Watch and a sleep app). Clip to
    // the requested interval and merge before computing an asleep duration.
    static func sleepSeconds(_ intervals: [DateInterval], within window: DateInterval) -> TimeInterval {
        let clipped = intervals.compactMap { value -> DateInterval? in
            let start = max(window.start, value.start), end = min(window.end, value.end)
            return end > start ? DateInterval(start: start, end: end) : nil
        }.sorted { $0.start < $1.start }
        guard var current = clipped.first else { return 0 }
        var seconds: TimeInterval = 0
        for interval in clipped.dropFirst() {
            if interval.start <= current.end { current = DateInterval(start: current.start, end: max(current.end, interval.end)) }
            else { seconds += current.duration; current = interval }
        }
        return seconds + current.duration
    }
    static func approximateCoordinate(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
}
