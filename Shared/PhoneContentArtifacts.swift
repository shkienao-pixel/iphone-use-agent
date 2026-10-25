import Foundation
import CryptoKit

/// Immutable phone-local input material. The reference binds an opaque ID to the
/// exact UTF-8 bytes; Unicode normalization and newline rewriting are forbidden.
struct PhoneContentArtifact: Codable, Equatable, Identifiable, Sendable {
    static let maximumCharacters = 40_000
    var id: UUID
    var title: String
    var body: String
    var createdAt: Date
    var sha256: String
    var characterCount: Int
    var utf16Count: Int
    var utf8Count: Int
    var lineBreakCount: Int
    var lineFeedCount: Int
    var carriageReturnCount: Int
    var reference: String { "content:" + id.uuidString.lowercased() + ":" + sha256 }

    init(title: String, body: String, id: UUID = UUID(), createdAt: Date = Date()) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 160, !body.isEmpty, body.count <= Self.maximumCharacters,
              body.utf8.count <= 240_000 else { throw PhoneContentError.invalidContent }
        self.id = id; self.title = title; self.body = body; self.createdAt = createdAt
        sha256 = Self.digest(body); characterCount = body.count
        utf16Count = body.utf16.count; utf8Count = body.utf8.count
        lineFeedCount = body.unicodeScalars.filter { $0.value == 10 }.count
        carriageReturnCount = body.unicodeScalars.filter { $0.value == 13 }.count
        lineBreakCount = lineFeedCount + carriageReturnCount - body.components(separatedBy: "\r\n").count + 1
    }
    func validate() throws {
        let actual = try Self(title: title, body: body, id: id, createdAt: createdAt)
        guard self == actual, createdAt.timeIntervalSince1970.isFinite else { throw PhoneContentError.invalidContent }
    }
    static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func validReference(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "content", let id = UUID(uuidString: String(parts[1])),
              parts[1] == Substring(id.uuidString.lowercased()), parts[2].count == 64 else { return false }
        return parts[2].utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    var metadata: [String: String] {
        ["artifact_ref": reference, "title": title, "sha256": sha256,
         "characters": String(characterCount), "utf16_units": String(utf16Count), "utf8_bytes": String(utf8Count),
         "line_breaks": String(lineBreakCount), "lf": String(lineFeedCount), "cr": String(carriageReturnCount)]
    }
}

enum PhoneContentError: LocalizedError {
    case invalidContent, invalidReference, unavailable, foregroundRequired, clipboardMismatch, notPrepared, expiredPreparation
    var errorDescription: String? {
        switch self {
        case .invalidContent: return "正文产物无效；标题需 1–160 字，正文需 1–40000 字，原文不会被截断或改写"
        case .invalidReference: return "正文引用无效或内容摘要不符，请使用完整 content:ID:SHA256 引用"
        case .unavailable: return "本机正文存储暂时不可用；原文件已保留，没有覆盖"
        case .foregroundRequired: return "请回到 Sela 前台准备本机剪贴板；后台不会写入剪贴板"
        case .clipboardMismatch: return "剪贴板实际回读与正文不一致；没有获得可用的粘贴准备回执"
        case .notPrepared: return "本次 App 会话没有该正文的有效准备回执，请在前台重新准备；先核对目标已有内容，避免重复粘贴"
        case .expiredPreparation: return "剪贴板准备回执已过期，请先核对目标已有内容，再回到前台重新准备"
        }
    }
}

/// This receipt verifies only our phone-local clipboard write/read-back. It is
/// never evidence of field focus, a paste, a saved note, or a sent message.
struct PhoneClipboardPreparation: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable { case preparing, prepared, unknown }
    var id: UUID
    var artifactReference: String
    var preparedAt: Date
    var expiresAt: Date
    var changeCount: Int?
    var state: State
    var detail: String
}

struct PhoneContentComparison: Codable, Equatable, Sendable {
    enum Scope: String, Codable { case fullReadback, fragments }
    enum Outcome: String, Codable { case exact, partial, mismatch, unknown }
    var scope: Scope
    var outcome: Outcome
    var expectedSHA256: String
    var observedSHA256: String?
    var observedCharacters: Int

    /// Call only with independently acquired target text, never model assertions.
    /// Screen OCR fragments cannot establish full-text or newline correctness.
    static func compare(_ observed: String?, with artifact: PhoneContentArtifact, scope: Scope) -> Self {
        let hash = observed.map(PhoneContentArtifact.digest)
        let outcome: Outcome
        if let observed, !observed.isEmpty {
            if scope == .fragments {
                outcome = Data(artifact.body.utf8).range(of: Data(observed.utf8)) == nil ? .mismatch : .partial
            } else { outcome = hash == artifact.sha256 ? .exact : .mismatch }
        } else { outcome = .unknown }
        return Self(scope: scope, outcome: outcome, expectedSHA256: artifact.sha256,
                    observedSHA256: hash, observedCharacters: observed?.count ?? 0)
    }
}
