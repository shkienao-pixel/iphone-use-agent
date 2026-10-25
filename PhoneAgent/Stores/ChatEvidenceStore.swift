import Foundation

/// Persists raw frames, accepted message order, segment summaries and reports
/// together. A failed write never advances the in-memory checkpoint.
@MainActor
final class ChatEvidenceStore {
    static let shared = ChatEvidenceStore()
    private struct Document: Codable { var version = 1; var sessions: [ChatEvidenceSession] = [] }
    private var document = Document()
    private var readable = true
    private let url: URL
    private(set) var error = ""
    var sessions: [ChatEvidenceSession] { document.sessions }

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneAgent/chat-evidence.json")
        guard FileManager.default.fileExists(atPath: self.url.path) else { return }
        do {
            guard (try self.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 40_000_000 else { throw ChatEvidenceError.unavailable }
            let value = try JSONDecoder().decode(Document.self, from: Data(contentsOf: self.url))
            try Self.validate(value)
            document = value
        } catch { readable = false; self.error = ChatEvidenceError.unavailable.localizedDescription }
    }

    func session(id: String) throws -> ChatEvidenceSession {
        guard readable, let value = document.sessions.first(where: { $0.id == id }) else { throw ChatEvidenceError.unavailable }
        return value
    }

    @discardableResult
    func prepare(_ request: ChatReadRequest) throws -> ChatEvidenceSession {
        guard readable else { throw ChatEvidenceError.unavailable }
        try request.validate()
        if let existing = document.sessions.first(where: { $0.id == request.scopeID }) {
            guard existing.request == request else { throw ChatEvidenceError.invalidRequest }
            return existing
        }
        guard document.sessions.count < 100 else { throw ChatEvidenceError.limit }
        let value = ChatEvidenceSession(request: request)
        try save(value)
        return value
    }

    func save(_ session: ChatEvidenceSession) throws {
        guard readable else { throw ChatEvidenceError.unavailable }
        if let old = document.sessions.first(where: { $0.id == session.id }) {
            guard old.request == session.request else { throw ChatEvidenceError.invalidRequest }
            if old.pageSelection != nil {
                guard old.pageSelection == session.pageSelection, old.frames == session.frames,
                      old.messages == session.messages, old.unmergedBatches == session.unmergedBatches else { throw ChatEvidenceError.invalidRequest }
            }
        }
        var next = document
        next.sessions.removeAll { $0.id == session.id }; next.sessions.append(session)
        try Self.validate(next)
        try persist(next)
    }

    @discardableResult
    func appendSummary(_ segment: ChatSummarySegment, sessionID: String,
                       expectedSelectedMessageIDs: [String], updatedAt: Date) throws -> ChatEvidenceSession {
        try append(.summary(segment), sessionID: sessionID,
            expectedSelectedMessageIDs: expectedSelectedMessageIDs, updatedAt: updatedAt)
    }

    @discardableResult
    func appendReport(_ report: ChatSummaryReport, sessionID: String,
                      expectedSelectedMessageIDs: [String], updatedAt: Date) throws -> ChatEvidenceSession {
        try append(.report(report), sessionID: sessionID,
            expectedSelectedMessageIDs: expectedSelectedMessageIDs, updatedAt: updatedAt)
    }

    private enum DerivedAppend { case summary(ChatSummarySegment), report(ChatSummaryReport) }

    /// Only this synchronous constructor can reuse native raw validation. It
    /// starts from the current private validated value and cannot accept a
    /// caller's request, raw rows, frame, selection, or mutation closure.
    private func append(_ value: DerivedAppend, sessionID: String,
                        expectedSelectedMessageIDs: [String], updatedAt: Date) throws -> ChatEvidenceSession {
        var current = try session(id: sessionID)
        guard current.selectedMessages.map(\.id) == expectedSelectedMessageIDs else { throw ChatEvidenceError.invalidSummary }
        switch value {
        case .summary(let segment): current.summaries.append(segment)
        case .report(let report): current.reports.append(report)
        }
        current.updatedAt = updatedAt
        var next = document
        next.sessions.removeAll { $0.id == sessionID }; next.sessions.append(current)
        // All raw values in next were copied unchanged from this private
        // validated Document. This is construction, not Equatable authority.
        try Self.validate(next, rawCopiedFromValidatedDocument: true)
        try persist(next)
        return current
    }

    private func persist(_ next: Document) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(next)
        guard data.count <= 40_000_000 else { throw ChatEvidenceError.limit }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { throw ChatEvidenceError.unavailable }
        document = next
    }

    private static func validate(_ document: Document, rawCopiedFromValidatedDocument: Bool = false) throws {
        guard document.version == 1, document.sessions.count <= 100,
              Set(document.sessions.map(\.id)).count == document.sessions.count else { throw ChatEvidenceError.unavailable }
        for session in document.sessions {
            try session.request.validate()
            let unmerged = session.unmergedBatches ?? []
            let frameIDs = session.frames.map(\.id), unmergedIDs = unmerged.map(\.id)
            guard session.messages.count <= 10_000, session.frames.count + unmerged.count <= 300,
                  Set(session.messages.map(\.id)).count == session.messages.count,
                  Set(frameIDs + unmergedIDs).count == frameIDs.count + unmergedIDs.count,
                  Set(unmergedIDs).isDisjoint(with: session.messages.map(\.id) + session.summaries.map(\.id) + session.reports.map(\.id)),
                  Set(session.summaries.map(\.id)).count == session.summaries.count,
                  Set(session.reports.map(\.id)).count == session.reports.count else { throw ChatEvidenceError.unavailable }
            // Per-validation indexes retain complete values and source order.
            // Duplicate identifiers were rejected above; nothing is cached across saves.
            let frameByID = Dictionary(uniqueKeysWithValues: session.frames.map { ($0.id, $0) })
            let messageByID = Dictionary(uniqueKeysWithValues: session.messages.enumerated().map { ($0.element.id, ($0.offset, $0.element)) })
            let summaryByID = Dictionary(uniqueKeysWithValues: session.summaries.map { ($0.id, $0) })
            if !rawCopiedFromValidatedDocument {
                for (index, frame) in session.frames.enumerated() {
                    try frame.validate(for: session.request.conversation, previousFrame: index > 0 ? session.frames[index - 1] : nil)
                }
                for raw in unmerged {
                    try raw.validate(request: session.request, sourceFrame: frameByID[raw.sourceFrameID])
                }
                for message in session.messages {
                    guard !message.id.isEmpty, !message.anchors.isEmpty,
                          message.anchors.contains(message.observation.anchor) else { throw ChatEvidenceError.unavailable }
                    for anchor in message.anchors {
                        guard let frame = frameByID[anchor.frameID],
                              frame.rows.contains(where: { $0.anchor == anchor && $0.sameOccurrenceCandidate(as: message.observation) }) else { throw ChatEvidenceError.unavailable }
                    }
                }
            }
            try validatePageSelection(session)
            let messageOrder = Dictionary(uniqueKeysWithValues: session.messages.enumerated().map { ($0.element.id, $0.offset) })
            for segment in session.summaries {
                try ChatSummaryValidation.validateProducer(id: segment.id, version: segment.validationVersion, kind: .segment)
                let ids = Set(segment.messageIDs + segment.contextMessageIDs)
                if case .currentPage = session.request.range {
                    guard let selection = session.pageSelection, ids.isSubset(of: selection.messageIDs) else { throw ChatEvidenceError.invalidSummary }
                }
                let messages = ids.compactMap { messageByID[$0] }.sorted { $0.0 < $1.0 }.map { $0.1 }
                guard !segment.messageIDs.isEmpty, messages.count == segment.messageIDs.count + segment.contextMessageIDs.count else { throw ChatEvidenceError.unavailable }
                try ChatEvidenceSummarizer.validate(claims: segment.claims, messages: messages, validationVersion: segment.validationVersion)
                guard segment.claims.allSatisfy({ !Set($0.citations.map(\.messageID)).isDisjoint(with: segment.messageIDs) }) else { throw ChatEvidenceError.unavailable }
                let ordered = segment.messageIDs.compactMap { messageOrder[$0] }
                guard ordered == ordered.sorted() else { throw ChatEvidenceError.unavailable }
            }
            for report in session.reports {
                try ChatSummaryValidation.validateProducer(id: report.id, version: report.validationVersion, kind: .report)
                guard report.scopeID == session.id, report.conversation == session.request.conversation,
                      report.range == session.request.range, report.segmentIDs.allSatisfy({ summaryByID[$0] != nil }),
                      !report.messageIDs.isEmpty, Set(report.messageIDs).count == report.messageIDs.count,
                      report.messageIDs.allSatisfy({ messageByID[$0] != nil }) else { throw ChatEvidenceError.unavailable }
                if case .currentPage = session.request.range {
                    guard report.messageIDs == session.pageSelection?.messageIDs else { throw ChatEvidenceError.invalidSummary }
                }
                let messages = report.messageIDs.compactMap { messageByID[$0]?.1 }
                let ordered = report.messageIDs.compactMap { messageOrder[$0] }
                guard ordered == ordered.sorted(), messages.allSatisfy({ session.request.range.contains($0) }) else { throw ChatEvidenceError.unavailable }
                if report.validationVersion == ChatSummaryValidation.currentVersion {
                    guard report.segmentIDs.allSatisfy({ id in
                        summaryByID[id].map { ChatSummaryValidation.isCurrent(id: $0.id, version: $0.validationVersion, kind: .segment) } == true
                    }) else { throw ChatEvidenceError.invalidSummary }
                }
                try ChatEvidenceSummarizer.validate(claims: report.claims, messages: messages, validationVersion: report.validationVersion)
            }
        }
    }

    private static func validatePageSelection(_ session: ChatEvidenceSession) throws {
        guard case let .currentPage(limit) = session.request.range else {
            guard session.pageSelection == nil else { throw ChatEvidenceError.invalidRequest }
            return
        }
        guard session.frames.count <= 1 else { throw ChatEvidenceError.invalidRequest }
        guard let frame = session.frames.first else {
            guard session.pageSelection == nil, session.messages.isEmpty,
                  session.state != .complete else { throw ChatEvidenceError.invalidRequest }
            return
        }
        guard let selected = session.pageSelection, selected.version == 1,
              selected.scopeID == session.id, selected.requestedConversation == session.request.conversation,
              selected.frameID == frame.id, selected.capturedAt == frame.snapshot.capturedAt,
              selected.limit == limit, frame.conversation.kind != .controlledScroll,
              session.messages.count == frame.rows.count,
              zip(session.messages, frame.rows).allSatisfy({ $0.observation == $1 && $0.anchors == [$1.anchor] }),
              selected.messageIDs == Array(session.messages.suffix(limit)).map(\.id) else { throw ChatEvidenceError.invalidRequest }
    }
}
