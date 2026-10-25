import Foundation

enum ChatEvidenceError: LocalizedError {
    case invalidRequest, wrongConversation, ambiguousContinuity, invalidFrame, unavailable, invalidSummary, limit, latestEndUnknown, pageAlreadyBound
    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "聊天读取需明确稳定会话、设备，以及时间或条数范围"
        case .wrongConversation: return "当前会话身份未核对或与指定会话不符，已停止读取"
        case .ambiguousContinuity: return "消息发生位置或会话延续未独立验证，已停止；本地 OCR 当前仅支持独立核验的一页，未猜测跨页合并"
        case .invalidFrame: return "聊天画面、来源锚点或时间信息无效，未纳入消息证据"
        case .unavailable: return "聊天证据文件损坏、版本不支持或无法保存，未覆盖原文件"
        case .invalidSummary: return "总结存在无效引用、未读媒介结论或无原文依据的负责人/期限，未作为有效总结保存"
        case .limit: return "聊天读取达到本地安全上限，已保存检查点"
        case .latestEndUnknown: return "无法独立证明会话最新端，未将当前页作为‘最近 N 条’读取或上传模型；可新建‘当前可见页’范围"
        case .pageAlreadyBound: return "此范围已固定到首次读取的可见页，不能续读或换页；可查看、导出、总结已有样本，读取新页需新建范围"
        }
    }
}

struct ChatConversationTarget: Codable, Equatable {
    var stableID: String
    var title: String
    var deviceKey: String
}

enum ChatReadRange: Codable, Equatable {
    /// Legacy encoding retained. This OCR app cannot prove the latest end.
    case latest(count: Int)
    /// The bottom-most observed rows of the first independently identified page.
    case currentPage(limit: Int)
    /// Absolute dates only. A screen's capture time is never a message time.
    case time(start: Date, end: Date)
    func contains(_ message: ChatEvidenceMessage) -> Bool {
        switch self {
        // `contains` preserves old report provenance, not new upload authority.
        case .latest, .currentPage: return true
        case let .time(start, end): return message.observation.sentAt.map { start <= $0 && $0 <= end } ?? false
        }
    }
}

struct ChatReadRequest: Codable, Equatable {
    var scopeID: String
    var conversation: ChatConversationTarget
    var range: ChatReadRange
    var maxPages = 100
    func validate() throws {
        let values = [scopeID, conversation.stableID, conversation.title]
        guard values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 180 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              !conversation.deviceKey.isEmpty, conversation.deviceKey.count <= 1024,
              !conversation.deviceKey.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (1...300).contains(maxPages) else { throw ChatEvidenceError.invalidRequest }
        switch range {
        case let .latest(count): guard (1...5000).contains(count) else { throw ChatEvidenceError.invalidRequest }
        case let .currentPage(limit): guard (1...200).contains(limit) else { throw ChatEvidenceError.invalidRequest }
        case let .time(start, end): guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, start <= end else { throw ChatEvidenceError.invalidRequest }
        }
    }
}

enum ChatReadDirection: String, Codable { case older, newer }
enum ChatMediaKind: String, Codable { case voice, image, video, attachment, sticker, unknown }
struct ChatUnreadMedia: Codable, Equatable {
    var kind: ChatMediaKind
    var label: String
}

/// A frame-local location, not a platform message ID. IDs assigned by OCR must
/// never be reused as cross-frame or cross-session message identity.
struct ChatSourceAnchor: Codable, Equatable {
    var frameID: String
    var elementIDs: [String]
    var rect: PhoneUIRect
    var capturedAt: Date
}

struct ChatObservedMessage: Codable, Equatable {
    var platformMessageID: String? = nil
    var speaker: String?
    var sentAt: Date? = nil
    var timeLabel: String? = nil
    var text: String
    var unreadMedia: [ChatUnreadMedia] = []
    var anchor: ChatSourceAnchor
    /// Matching is deliberately richer than text equality. Sequence uniqueness
    /// is still required when the platform does not expose real message IDs.
    func sameOccurrenceCandidate(as other: Self) -> Bool {
        if let a = platformMessageID, let b = other.platformMessageID {
            return a == b && text == other.text && speaker == other.speaker && sentAt == other.sentAt && unreadMedia == other.unreadMedia
        }
        guard platformMessageID == nil, other.platformMessageID == nil else { return false }
        return text == other.text && speaker == other.speaker && sentAt == other.sentAt && timeLabel == other.timeLabel && unreadMedia == other.unreadMedia
    }
}

struct ChatConversationProof: Codable, Equatable {
    enum Kind: String, Codable { case builtInTransfer, verifiedPlatformID, contactProfileNavigation, controlledScroll }
    var stableID: String
    var title: String
    var kind: Kind
    /// Current-frame evidence. A display name alone is never an identity proof.
    var evidenceElementIDs: [String]
    var platformIdentityElementID: String? = nil
    var previousFrameID: String? = nil
    var scrollDirection: ChatReadDirection? = nil
    var contactNavigation: WeChatContactNavigationEvidence? = nil
}

struct ChatEvidenceFrame: Codable, Equatable {
    var id: String
    var snapshot: PhoneUISnapshot
    var conversation: ChatConversationProof
    var rows: [ChatObservedMessage]
    /// This may only be true after a locally observed history boundary.
    var reachedBoundary = false
    /// Identity authority is not restored from this field. It records the
    /// capture stream that the live adapter verified during this read run.
    var captureSessionID: UUID? = nil

    func validate(for target: ChatConversationTarget, previousFrame: ChatEvidenceFrame? = nil) throws {
        guard !snapshot.blockingOverlay, snapshot.deviceKey == target.deviceKey,
              conversation.stableID == target.stableID, conversation.title == target.title,
              let page = WeChatContactIdentity.chatPage(snapshot: snapshot, title: target.title),
              !conversation.evidenceElementIDs.isEmpty,
              conversation.evidenceElementIDs.allSatisfy({ snapshot.element(id: $0) != nil }) else { throw ChatEvidenceError.wrongConversation }
        switch conversation.kind {
        case .builtInTransfer:
            guard PhonePageAdapters.canonicalConversation(target.title) == target.stableID,
                  let proof = PhonePageAdapters.selfTransferEvidence(in: snapshot), conversation.evidenceElementIDs.contains(proof.id) else { throw ChatEvidenceError.wrongConversation }
        case .verifiedPlatformID:
            guard let identityID = conversation.platformIdentityElementID,
                  conversation.evidenceElementIDs.contains(identityID),
                  let identity = snapshot.element(id: identityID), identity.source == "platform_identity", identity.label == target.stableID else { throw ChatEvidenceError.wrongConversation }
        case .contactProfileNavigation:
            guard let navigation = conversation.contactNavigation,
                  Set(page.evidence).isSubset(of: conversation.evidenceElementIDs) else { throw ChatEvidenceError.wrongConversation }
            try navigation.validate(target: target, chat: snapshot, captureSessionID: captureSessionID)
        case .controlledScroll:
            guard let previous = previousFrame, let captureSessionID, let direction = conversation.scrollDirection,
                  previous.captureSessionID == captureSessionID,
                  conversation.previousFrameID == previous.id,
                  previous.snapshot.deviceKey == target.deviceKey,
                  previous.conversation.stableID == target.stableID, previous.conversation.title == target.title,
                  previous.snapshot.capturedAt < snapshot.capturedAt,
                  Set(page.evidence).isSubset(of: conversation.evidenceElementIDs) else { throw ChatEvidenceError.wrongConversation }
            // Historical archive validation only. Local sequence uniqueness
            // does not prove that two visible copies are one occurrence.
            // Fresh live adapters never mint this legacy proof.
            _ = try ChatMessageContinuity.overlap(existing: previous.rows, incoming: rows, direction: direction)
        }
        guard !id.isEmpty, id.count <= 180, rows.count <= 200,
              snapshot.capturedAt.timeIntervalSince1970.isFinite,
              Set(rows.compactMap(\.platformMessageID)).count == rows.compactMap(\.platformMessageID).count else { throw ChatEvidenceError.invalidFrame }
        var lastY = -Double.infinity
        for row in rows {
            guard row.anchor.frameID == id, row.anchor.capturedAt == snapshot.capturedAt,
                  row.anchor.rect.valid, row.anchor.rect.centerY >= lastY,
                  !row.anchor.elementIDs.isEmpty,
                  row.anchor.elementIDs.allSatisfy({ snapshot.element(id: $0) != nil }),
                  row.text.count <= 8000, !row.text.isEmpty || !row.unreadMedia.isEmpty,
                  (row.speaker?.count ?? 0) <= 180, (row.timeLabel?.count ?? 0) <= 180,
                  row.unreadMedia.count <= 10, row.unreadMedia.allSatisfy({ !$0.label.isEmpty && $0.label.count <= 512 }),
                  row.sentAt.map({ $0.timeIntervalSince1970.isFinite && $0 <= snapshot.capturedAt }) ?? true,
                  row.platformMessageID.map({ !$0.isEmpty && $0.count <= 180 }) ?? true else { throw ChatEvidenceError.invalidFrame }
            lastY = row.anchor.rect.centerY
        }
    }

    static func fromContactNavigation(snapshot: PhoneUISnapshot, id: String, captureSessionID: UUID,
                                      target: ChatConversationTarget, navigation: WeChatContactNavigationEvidence,
                                      reachedBoundary: Bool = false, timeZone: TimeZone = .current) throws -> Self {
        guard let page = WeChatContactIdentity.chatPage(snapshot: snapshot, title: target.title) else { throw ChatEvidenceError.wrongConversation }
        var excluded: [String] = []
        if target.stableID == "wechat.builtin.file-transfer" {
            // The reserved account is independently validated by navigation.
            // Exclude only the existing exact system anchor, never a global
            // phrase match in ordinary contacts or outside this geometry.
            let candidates = PhonePageAdapters.selfTransferEvidenceCandidates(in: snapshot)
            guard candidates.count <= 1 else { throw ChatEvidenceError.ambiguousContinuity }
            excluded = candidates.map(\.id)
        }
        let rows = observedRows(snapshot: snapshot, id: id, page: page, excluding: excluded, timeZone: timeZone)
        let result = Self(id: id, snapshot: snapshot,
            conversation: .init(stableID: target.stableID, title: target.title, kind: .contactProfileNavigation,
                evidenceElementIDs: page.evidence, contactNavigation: navigation), rows: rows,
            reachedBoundary: reachedBoundary, captureSessionID: captureSessionID)
        try result.validate(for: target)
        return result
    }

    /// Conservative OCR adapter for the independently identifiable built-in
    /// transfer conversation. It does not invent contact IDs, dates or names.
    /// A richer platform adapter can supply grouped bubbles and verified IDs.
    static func from(snapshot: PhoneUISnapshot, id: String = UUID().uuidString, reachedBoundary: Bool = false,
                     timeZone: TimeZone = .current) throws -> Self {
        let titleCandidates = snapshot.elements.filter { $0.source == "ocr" && $0.rect.valid && $0.rect.centerY < 0.16 && (0.28...0.76).contains($0.rect.centerX) && PhonePageAdapters.selfConversation($0.label) }
        guard titleCandidates.count == 1, let stableID = PhonePageAdapters.canonicalConversation(titleCandidates[0].label),
              let proof = PhonePageAdapters.selfTransferEvidence(in: snapshot),
              let page = WeChatContactIdentity.chatPage(snapshot: snapshot, title: titleCandidates[0].label) else { throw ChatEvidenceError.wrongConversation }
        let title = titleCandidates[0].label
        let rows = observedRows(snapshot: snapshot, id: id, page: page, excluding: [proof.id], timeZone: timeZone)
        let result = Self(id: id, snapshot: snapshot, conversation: .init(stableID: stableID, title: title, kind: .builtInTransfer,
            evidenceElementIDs: page.evidence + [proof.id]), rows: rows, reachedBoundary: reachedBoundary)
        try result.validate(for: .init(stableID: stableID, title: title, deviceKey: snapshot.deviceKey))
        return result
    }

    static func observedRows(snapshot: PhoneUISnapshot, id: String, page: PhonePageIdentity,
                                     excluding: [String], timeZone: TimeZone) -> [ChatObservedMessage] {
        let ordered = page.messages.filter { !excluding.contains($0.id) }.sorted { $0.rect.centerY < $1.rect.centerY }
        var timeLabel: String?
        var absoluteTime: Date?
        var rows: [ChatObservedMessage] = []
        for element in ordered {
            let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
            // Centered time separators remain labels only: "昨天" or "10:30"
            // cannot identify an absolute message date safely.
            if abs(element.rect.centerX - 0.5) < 0.1, isTimeLabel(label) {
                timeLabel = label
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
                formatter.timeZone = timeZone; formatter.dateFormat = "yyyy年M月d日 HH:mm"; formatter.isLenient = false
                absoluteTime = label.range(of: #"^\d{4}年\d{1,2}月\d{1,2}日 \d{1,2}:\d{2}$"#, options: .regularExpression) != nil ? formatter.date(from: label) : nil
                continue
            }
            let media: [ChatUnreadMedia]
            if ["[语音]", "语音消息", "[voice]"].contains(label.lowercased()) || label.range(of: #"^\d{1,3}(?:[″"']|秒)$"#, options: .regularExpression) != nil { media = [.init(kind: .voice, label: label)] }
            else if ["[图片]", "图片", "[image]"].contains(label.lowercased()) { media = [.init(kind: .image, label: label)] }
            else if ["[视频]", "视频", "[video]"].contains(label.lowercased()) { media = [.init(kind: .video, label: label)] }
            else if ["[文件]", "[file]", "附件"].contains(label.lowercased()) { media = [.init(kind: .attachment, label: label)] }
            else { media = [] }
            rows.append(ChatObservedMessage(speaker: element.rect.centerX > 0.62 ? "我" : nil, sentAt: absoluteTime, timeLabel: timeLabel,
                text: label, unreadMedia: media, anchor: .init(frameID: id, elementIDs: [element.id], rect: element.rect, capturedAt: snapshot.capturedAt)))
        }
        return rows
    }
    private static func isTimeLabel(_ text: String) -> Bool {
        text.range(of: #"^(?:昨天|今天|星期[一二三四五六日天]|周[一二三四五六日天]|\d{4}年\d{1,2}月\d{1,2}日|\d{1,2}月\d{1,2}日)?\s*(?:上午|下午|晚上|凌晨)?\s*\d{1,2}:\d{2}$"#, options: .regularExpression) != nil
    }
}

/// Fresh occurrence proof is separate from the historical sequence heuristic.
/// Local text equality never establishes new cross-frame occurrence identity.
enum ChatMessageContinuity {
    /// Fresh merging requires independent occurrence identifiers. OCR factories
    /// do not supply them; a locally unique text sequence is insufficient.
    static func verifiedOccurrenceOverlap(existing: [ChatObservedMessage], incoming: [ChatObservedMessage], direction: ChatReadDirection) throws -> Int {
        guard !existing.isEmpty, !incoming.isEmpty else { throw ChatEvidenceError.ambiguousContinuity }
        for count in stride(from: min(existing.count, incoming.count), through: 1, by: -1) {
            let a = direction == .newer ? Array(existing.suffix(count)) : Array(existing.prefix(count))
            let b = direction == .newer ? Array(incoming.prefix(count)) : Array(incoming.suffix(count))
            if zip(a, b).allSatisfy({ $0.platformMessageID != nil && $0.platformMessageID == $1.platformMessageID && $0.sameOccurrenceCandidate(as: $1) }) { return count }
        }
        throw ChatEvidenceError.ambiguousContinuity
    }

    /// Legacy archive rule, never a fresh live occurrence/identity witness.
    static func overlap(existing: [ChatObservedMessage], incoming: [ChatObservedMessage], direction: ChatReadDirection) throws -> Int {
        guard !existing.isEmpty, !incoming.isEmpty else { throw ChatEvidenceError.ambiguousContinuity }
        for count in stride(from: min(existing.count, incoming.count), through: 1, by: -1) {
            let a = direction == .newer ? Array(existing.suffix(count)) : Array(existing.prefix(count))
            let b = direction == .newer ? Array(incoming.prefix(count)) : Array(incoming.suffix(count))
            guard zip(a, b).allSatisfy({ $0.sameOccurrenceCandidate(as: $1) }) else { continue }
            let platformProof = zip(a, b).allSatisfy { $0.platformMessageID != nil && $0.platformMessageID == $1.platformMessageID }
            guard platformProof || (count >= 2 && occurrences(of: a, in: existing) == 1 && occurrences(of: b, in: incoming) == 1) else { continue }
            return count
        }
        throw ChatEvidenceError.ambiguousContinuity
    }
    private static func occurrences(of sequence: [ChatObservedMessage], in values: [ChatObservedMessage]) -> Int {
        guard !sequence.isEmpty, sequence.count <= values.count else { return 0 }
        return (0...(values.count - sequence.count)).filter { start in
            sequence.indices.allSatisfy { sequence[$0].sameOccurrenceCandidate(as: values[start + $0]) }
        }.count
    }
}

enum ChatUnmergedReason: String, Codable {
    case unverifiedConversationContinuity, unverifiedOccurrenceContinuity
}

/// An observation without authority. No conversation proof, message identity,
/// citation or permission can be recovered from this raw batch.
struct ChatUnmergedObservation: Equatable {
    var id: String
    var snapshot: PhoneUISnapshot
    var rows: [ChatObservedMessage]
    var captureSessionID: UUID?
    var reason: ChatUnmergedReason
}

enum ChatEvidenceObservation {
    case frame(ChatEvidenceFrame)
    case unmerged(ChatUnmergedObservation)
}

struct ChatUnmergedCaptureError: Error {
    var observation: ChatUnmergedObservation
}

struct ChatUnmergedBatch: Codable, Equatable, Identifiable {
    var version = 1
    var id: String
    var snapshot: PhoneUISnapshot
    var rows: [ChatObservedMessage]
    var captureSessionID: UUID?
    /// Requested context only; neither field asserts actual observed identity.
    var scopeID: String
    var requestedConversation: ChatConversationTarget
    var direction: ChatReadDirection
    var reason: ChatUnmergedReason
    var sourceFrameID: String

    func validate(request: ChatReadRequest, sourceFrame: ChatEvidenceFrame?) throws {
        guard version == 1, scopeID == request.scopeID, requestedConversation == request.conversation,
              !id.isEmpty, id.count <= 180, let sourceFrame, sourceFrame.id == sourceFrameID,
              sourceFrame.snapshot.capturedAt < snapshot.capturedAt,
              snapshot.deviceKey == request.conversation.deviceKey,
              snapshot.capturedAt.timeIntervalSince1970.isFinite, rows.count <= 200,
              snapshot.elements.count <= 1000,
              Set(snapshot.elements.map(\.id)).count == snapshot.elements.count,
              snapshot.elements.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 180 && $0.rect.valid && $0.label.count <= 8000 && !$0.source.isEmpty && $0.source.count <= 80 }),
              Set(rows.compactMap(\.platformMessageID)).count == rows.compactMap(\.platformMessageID).count else { throw ChatEvidenceError.invalidFrame }
        var lastY = -Double.infinity
        for row in rows {
            guard row.anchor.frameID == id, row.anchor.capturedAt == snapshot.capturedAt,
                  row.anchor.rect.valid, row.anchor.rect.centerY >= lastY,
                  !row.anchor.elementIDs.isEmpty, Set(row.anchor.elementIDs).count == row.anchor.elementIDs.count,
                  row.anchor.elementIDs.allSatisfy({ snapshot.element(id: $0) != nil }),
                  row.text.count <= 8000, !row.text.isEmpty || !row.unreadMedia.isEmpty,
                  (row.speaker?.count ?? 0) <= 180, (row.timeLabel?.count ?? 0) <= 180,
                  row.unreadMedia.count <= 10, row.unreadMedia.allSatisfy({ !$0.label.isEmpty && $0.label.count <= 512 }),
                  row.sentAt.map({ $0.timeIntervalSince1970.isFinite && $0 <= snapshot.capturedAt }) ?? true,
                  row.platformMessageID.map({ !$0.isEmpty && $0.count <= 180 }) ?? true else { throw ChatEvidenceError.invalidFrame }
            // These raw anchors describe the supplied local elements, not an
            // independent occurrence. Geometry must still match their source.
            let rects = row.anchor.elementIDs.compactMap { snapshot.element(id: $0)?.rect }
            let minX = rects.map(\.x).min()!, minY = rects.map(\.y).min()!
            let maxX = rects.map { $0.x + $0.width }.max()!, maxY = rects.map { $0.y + $0.height }.max()!
            let sourceRect = PhoneUIRect(x: minX, y: minY, width: maxX-minX, height: maxY-minY)
            // Single-element rects preserve their original floating values.
            guard row.anchor.rect == (rects.count == 1 ? rects[0] : sourceRect) else { throw ChatEvidenceError.invalidFrame }
            lastY = row.anchor.rect.centerY
        }
    }
}

struct ChatEvidenceMessage: Codable, Equatable, Identifiable {
    /// Session-local citation identity; never advertised as a WeChat message ID.
    var id: String
    var observation: ChatObservedMessage
    var anchors: [ChatSourceAnchor]
}

enum ChatReadState: String, Codable { case reading, complete, partial, ambiguous, stopped }

struct ChatPageSelection: Codable, Equatable {
    var version = 1
    var scopeID: String
    var requestedConversation: ChatConversationTarget
    var frameID: String
    var capturedAt: Date
    var limit: Int
    var messageIDs: [String]
}

struct ChatEvidenceSession: Codable, Equatable, Identifiable {
    var id: String { request.scopeID }
    var request: ChatReadRequest
    var messages: [ChatEvidenceMessage] = []
    var frames: [ChatEvidenceFrame] = []
    /// Nil preserves legacy archive encoding. These batches are never messages.
    var unmergedBatches: [ChatUnmergedBatch]? = nil
    /// Once committed, immutable under the same request/scope.
    var pageSelection: ChatPageSelection? = nil
    var state: ChatReadState = .reading
    var detail = "尚未读取"
    var updatedAt: Date = Date()
    var summaries: [ChatSummarySegment] = []
    var reports: [ChatSummaryReport] = []
    var selectedMessages: [ChatEvidenceMessage] {
        switch request.range {
        case .latest: return [] // No observable latest-end authority exists.
        case .time: return messages.filter { request.range.contains($0) }
        case .currentPage:
            guard let selection = pageSelection else { return [] }
            let lookup = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return selection.messageIDs.compactMap { lookup[$0] }
        }
    }
    var isLatestEndUnknown: Bool {
        if case .latest = request.range { return true }
        return false
    }
    var unreadTimeMessageIDs: [String] { messages.filter { $0.observation.sentAt == nil }.map(\.id) }
    var knownTimeOrderConflict: Bool {
        let times = messages.compactMap { $0.observation.sentAt }
        return zip(times, times.dropFirst()).contains { $0 > $1 }
    }
    var hasLegacyOccurrenceAssociations: Bool {
        frames.contains { $0.conversation.kind == .controlledScroll } || messages.contains {
            $0.observation.platformMessageID == nil && Set($0.anchors.map(\.frameID)).count > 1
        }
    }
}

enum ChatSummaryCategory: String, Codable, Hashable { case fact, decision, task, inference, conflict, correction }
struct ChatEvidenceCitation: Codable, Equatable, Hashable { var messageID: String; var quote: String }
struct ChatSummaryClaim: Codable, Equatable, Hashable {
    var category: ChatSummaryCategory
    var statement: String
    var citations: [ChatEvidenceCitation]
    var owner: String? = nil
    var deadline: String? = nil
}

/// A producer marker distinguishes new results from legacy archives when a
/// version field is removed. It is a schema invariant, not a cryptographic seal.
enum ChatSummaryValidation {
    static let currentVersion = 2
    enum Kind: String { case segment = "cs-v2-", report = "cr-v2-" }

    static func validateProducer(id: String, version: Int?, kind: Kind) throws {
        guard version == nil || version == currentVersion else { throw ChatEvidenceError.invalidSummary }
        let carriesCurrentMarker = [Kind.segment.rawValue, Kind.report.rawValue].contains { id.hasPrefix($0) }
        if carriesCurrentMarker || version == currentVersion {
            guard version == currentVersion, id.hasPrefix(kind.rawValue),
                  UUID(uuidString: String(id.dropFirst(kind.rawValue.count))) != nil else {
                throw ChatEvidenceError.invalidSummary
            }
        }
    }
    static func isCurrent(id: String, version: Int?, kind: Kind) -> Bool {
        version == currentVersion && (try? validateProducer(id: id, version: version, kind: kind)) != nil
    }
    /// Array order is retained. Identical text from different message IDs is
    /// different evidence and therefore a different complete claim tuple.
    static func deduplicated(_ claims: [ChatSummaryClaim]) -> [ChatSummaryClaim] {
        var seen = Set<ChatSummaryClaim>()
        return claims.filter { seen.insert($0).inserted }
    }
}
struct ChatSummarySegment: Codable, Equatable, Identifiable {
    var id: String
    var messageIDs: [String]
    var contextMessageIDs: [String] = []
    var claims: [ChatSummaryClaim]
    var generatedAt: Date
    var validationVersion: Int? = nil
}
struct ChatSummaryReport: Codable, Equatable, Identifiable {
    var id: String
    var scopeID: String
    var conversation: ChatConversationTarget
    var range: ChatReadRange
    var messageIDs: [String]
    var segmentIDs: [String]
    var claims: [ChatSummaryClaim]
    var warnings: [String]
    var generatedAt: Date
    var validationVersion: Int? = nil
    func markdown() -> String {
        var lines = ["# \(conversation.title) 聊天总结", "", "实际纳入 \(messageIDs.count) 条消息；来源为本地证据引用，未证明对方已读。", ""]
        if case .latest = range {
            lines += ["历史范围的会话最新端未获独立证明；以下保留当时观察和引用，不代表已完整取得最近 N 条，也不授权重新上传模型。读取当前页需显式新建范围。", ""]
        }
        guard (try? ChatSummaryValidation.validateProducer(id: id, version: validationVersion, kind: .report)) != nil else {
            return (lines + ["总结验证版本不受支持；未展示结论或活动负责人/期限。"]).joined(separator: "\n")
        }
        if validationVersion == nil {
            if case .latest = range {
                lines += ["旧版历史报告：仅按原来源规则读取，未通过当前 v2 验证；更正项中最后引文未直接支持的负责人/期限不展示。此历史最近范围缺少最新端证明，不能重新上传；可显式新建当前可见页范围。", ""]
            } else {
                lines += ["旧版历史报告：仅按原来源规则读取，未通过当前 v2 验证；更正项中最后引文未直接支持的负责人/期限不展示。请显式重新总结，将按新规则重新处理当前选中的原消息范围，再恢复增量复用。", ""]
            }
        }
        let visibleClaims = ChatSummaryValidation.deduplicated(claims)
        if visibleClaims.contains(where: { value in
            guard value.category == .correction else { return false }
            let latest = value.citations.last?.quote ?? ""
            return value.owner.map({ !latest.contains($0) }) == true || value.deadline.map({ !latest.contains($0) }) == true
        }) {
            lines += ["有更正字段未被最后引文直接支持，已停止展示这些活动负责人/期限；原始历史字段与引文未修改。", ""]
        }
        for category in [ChatSummaryCategory.fact, .decision, .task, .inference, .conflict, .correction] {
            let values = visibleClaims.filter { $0.category == category }; guard !values.isEmpty else { continue }
            let name: String
            switch category { case .fact: name = "关键事实"; case .decision: name = "明确决定"; case .task: name = "明确待办"; case .inference: name = "模型推断（非明确承诺）"; case .conflict: name = "冲突（保留消息顺序）"; case .correction: name = "更正（保留消息顺序）" }
            lines += ["## " + name, ""]
            for value in values {
                let latestQuote = value.citations.last?.quote ?? ""
                let owner = value.owner.flatMap { category != .correction || latestQuote.contains($0) ? $0 : nil }
                let deadline = value.deadline.flatMap { category != .correction || latestQuote.contains($0) ? $0 : nil }
                lines.append("- " + value.statement + (owner.map { "；负责人：" + $0 } ?? "") + (deadline.map { "；期限：" + $0 } ?? ""))
                for cite in value.citations { lines.append("  - [\(cite.messageID)] \(cite.quote)") }
            }
            lines.append("")
        }
        if !warnings.isEmpty { lines += ["## 覆盖与未读范围", ""] + warnings.map { "- " + $0 } }
        return lines.joined(separator: "\n")
    }
}
