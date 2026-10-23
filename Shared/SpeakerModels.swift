import Foundation
import CryptoKit

struct SpeakerSettings: Codable, Equatable {
    var endpoint = "https://api.openai.com/v1/audio/transcriptions"
    var provider = "OpenAI"
    var model = "gpt-4o-transcribe-diarize"
    func validate() throws -> URL {
        guard !provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, provider.count <= 80,
              !model.isEmpty, model.count <= 120, model.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }), endpoint.count <= 2048,
              let c = URLComponents(string: endpoint), c.scheme == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, c.path.hasSuffix("/audio/transcriptions"),
              c.port == nil || (1...65535).contains(c.port!), let url = c.url else { throw AgentError.message("请填写独立 HTTPS 音频转写地址（结尾 /audio/transcriptions）、服务商和支持分段的模型；地址不含密钥或参数") }
        return url
    }
    static func validKey(_ key: String) -> Bool { !key.isEmpty && key.count <= 4096 && key.unicodeScalars.allSatisfy { (33...126).contains($0.value) } }
}
struct SpeakerSegment: Identifiable, Codable, Equatable {
    let id: UUID
    var speaker: Int
    var start: Double
    var end: Double
    var text: String
}
struct SpeakerDocument: Codable, Equatable {
    let recordingID: UUID
    let audioSHA256: String
    let duration: Double
    let receivedAt: Date
    let settings: SpeakerSettings
    let serviceText: String
    var speakers: [String]
    var segments: [SpeakerSegment]
    var edited = false
    static let maxFileBytes = 25_000_000
    static func digest(_ audio: Data) -> String { SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined() }
    func validate() throws {
        _ = try settings.validate()
        guard duration.isFinite, duration > 0, duration <= 600, receivedAt.timeIntervalSince1970.isFinite,
              audioSHA256.count == 64, audioSHA256.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (97...102).contains($0.value) }),
              serviceText.count <= 12000, !serviceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !speakers.isEmpty, speakers.count <= 20, Set(speakers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }).count == speakers.count,
              speakers.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 60 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }),
              !segments.isEmpty, segments.count <= 1200, Set(segments.map(\.id)).count == segments.count,
              segments.reduce(0, { $0 + $1.text.count }) <= 12000 else { throw AgentError.message("分段标题、文字、音频来源或数量超出范围，未保存") }
        var previous = -1.0
        for segment in segments {
            guard speakers.indices.contains(segment.speaker), segment.start.isFinite, segment.end.isFinite,
                  segment.start >= 0, segment.start < duration, segment.start >= previous, segment.end > segment.start, segment.end <= duration + 0.15,
                  !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, segment.text.count <= 4000 else { throw AgentError.message("片段需按开始时间排序，时间须位于录音内，且说话人 / 文字有效；没有自动删减或排序") }
            previous = segment.start
        }
    }
    static func decode(_ data: Data, recordingID: UUID, audioSHA256: String, duration: Double, settings: SpeakerSettings, date: Date) throws -> SpeakerDocument {
        struct Segment: Decodable { let speaker: String; let start: Double; let end: Double; let text: String }
        struct Envelope: Decodable { let text: String; let segments: [Segment] }
        guard data.count <= 1_000_000, let envelope = try? JSONDecoder().decode(Envelope.self, from: data), !envelope.segments.isEmpty, envelope.segments.count <= 1200 else { throw AgentError.message("服务未返回完整的说话人 JSON，未覆盖已有文字") }
        var ids: [String] = []; var segments: [SpeakerSegment] = []
        for s in envelope.segments {
            guard !s.speaker.isEmpty, s.speaker.count <= 80, !s.speaker.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw AgentError.message("服务说话人标签无效") }
            if !ids.contains(s.speaker) { ids.append(s.speaker) }
            guard ids.count <= 20 else { throw AgentError.message("服务返回超过 20 位说话人，未删减保存") }
            segments.append(.init(id: UUID(), speaker: ids.firstIndex(of: s.speaker)!, start: s.start, end: s.end, text: s.text))
        }
        let document = SpeakerDocument(recordingID: recordingID, audioSHA256: audioSHA256, duration: duration, receivedAt: date, settings: settings, serviceText: envelope.text, speakers: ids.indices.map { "说话人 " + String(UnicodeScalar(65 + $0)!) }, segments: segments)
        try document.validate(); return document
    }
    static func time(_ t: Double) -> String { guard t.isFinite, (0...601).contains(t) else { return "无效时间" }; let seconds = Int(t); return String(format: "%02d:%02d.%01d", seconds / 60, seconds % 60, Int((t - Double(seconds)) * 10)) }
    func referenceText() throws -> String {
        try validate()
        return "说话人分段转写（需回听核对；标签不证明真实身份，人工改名只代表用户注释）\n" + (edited ? "含用户编辑或片段移除，不是服务原始逐字转写。\n" : "来自服务分段草稿，可能存在归属或文字错误。\n") + segments.map { "[\(Self.time($0.start))–\(Self.time($0.end))] \(speakers[$0.speaker])：\($0.text)" }.joined(separator: "\n")
    }
    func exportText() throws -> String {
        try referenceText() + "\n\n接收方：\(settings.provider)\n接口：\(settings.endpoint)\n模型：\(settings.model)\n取得时间：\(ISO8601DateFormatter().string(from: receivedAt))\n录音 ID：\(recordingID.uuidString)\n音频 SHA256：\(audioSHA256)\n人工修改：\(edited ? "是" : "否")\n\n服务原始合并文字（未随人工编辑更新）：\n\(serviceText)"
    }
}

struct RecordingPlaybackRange: Equatable {
    let start: Double
    let end: Double
    static func make(start: Double, end: Double?, duration: Double) throws -> Self {
        let end = end ?? duration
        guard start.isFinite, end.isFinite, duration.isFinite, duration > 0, duration <= 600,
              start >= 0, start < duration, end > start, end <= duration + 0.15 else { throw AgentError.message("回听片段的时间无效，请核对开始和结束秒") }
        return .init(start: start, end: min(end, duration))
    }
}
