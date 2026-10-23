import Foundation

// Only compressed samples are retained. This is not a recording or an upload
// queue; stopping sampling clears it, and frames are never written to disk.
struct CameraObservationFrame {
    let jpeg: Data
    let capturedAt: Date
    let capturedUptime: TimeInterval
    let width: Int
    let height: Int
}

struct CameraObservationWindow {
    static let duration: TimeInterval = 12
    static let sampleLimit = 24
    static let requestLimit = 8
    static let frameBytes = 262_144
    private(set) var frames: [CameraObservationFrame] = []
    mutating func clear() { frames = [] }
    mutating func append(_ frame: CameraObservationFrame, now: TimeInterval) {
        guard now.isFinite, frame.capturedUptime.isFinite, frame.capturedUptime <= now,
              now - frame.capturedUptime <= Self.duration, frame.capturedAt.timeIntervalSinceReferenceDate.isFinite, !frame.jpeg.isEmpty,
              frame.jpeg.count <= Self.frameBytes, (1...640).contains(frame.width), (1...640).contains(frame.height) else { return }
        if let last = frames.last {
            if last.width != frame.width || last.height != frame.height { clear() }
            else if frame.capturedUptime <= last.capturedUptime { return }
        }
        frames.removeAll { now - $0.capturedUptime > Self.duration }
        frames.append(frame)
        if frames.count > Self.sampleLimit { frames.removeFirst(frames.count - Self.sampleLimit) }
    }
    func selected(now: TimeInterval) -> [CameraObservationFrame] {
        guard now.isFinite else { return [] }
        let source = frames.filter { $0.capturedUptime <= now && now - $0.capturedUptime <= Self.duration }
        guard source.count > Self.requestLimit else { return source }
        // Preserve the first and last samples and distribute the others across
        // the window; selecting the newest eight would discard earlier motion.
        return (0..<Self.requestLimit).map {
            source[Int((Double($0) * Double(source.count - 1) / Double(Self.requestLimit - 1)).rounded())]
        }
    }
    static func content(question: String, frames: [CameraObservationFrame], now: TimeInterval) throws -> [[String: Any]] {
        guard now.isFinite, (2...requestLimit).contains(frames.count), let first = frames.first, let last = frames.last,
              last.capturedUptime <= now, now - last.capturedUptime <= 2,
              now - first.capturedUptime <= duration else { throw AgentError.message("相机序列需有 2–8 张新画面；请稍等片刻后重试") }
        var previous = -Double.infinity
        let formatter = ISO8601DateFormatter()
        var content: [[String: Any]] = [["type": "text", "text": "用户问题：\(question)\n以下是按采集顺序排列的相机抽样画面，共 \(frames.count) 张。未提供连续视频或音频；画面之间的变化可能没有被采集，请区分可见事实、变化与不确定性。"]]
        for (index, frame) in frames.enumerated() {
            guard frame.capturedUptime.isFinite, frame.capturedAt.timeIntervalSinceReferenceDate.isFinite, frame.capturedUptime > previous, !frame.jpeg.isEmpty,
                  frame.jpeg.count <= frameBytes, frame.width == first.width, frame.height == first.height,
                  (1...640).contains(frame.width), (1...640).contains(frame.height) else { throw AgentError.message("相机序列顺序、尺寸或容量无效，未发送") }
            previous = frame.capturedUptime
            let offset = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), frame.capturedUptime - first.capturedUptime)
            content.append(["type": "text", "text": "样本 \(index + 1) · 相对 \(offset) 秒 · \(formatter.string(from: frame.capturedAt))"])
            content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + frame.jpeg.base64EncodedString(), "detail": "low"]])
        }
        return content
    }
}
