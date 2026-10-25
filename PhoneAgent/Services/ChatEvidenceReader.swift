import Foundation

/// The closures are the production integration boundary: obtain fresh local
/// OCR/platform evidence, then issue one bounded scroll and observe again.
/// There is no model decision per page and no authority to open another chat.
@MainActor
final class ChatEvidenceReader {
    typealias NextFrame = () async throws -> ChatEvidenceFrame
    typealias Scroll = (ChatReadDirection) async throws -> Void
    private let store: ChatEvidenceStore
    init(store: ChatEvidenceStore? = nil) { self.store = store ?? .shared }

    typealias NextObservation = () async throws -> ChatEvidenceObservation

    @discardableResult
    func read(request: ChatReadRequest, direction: ChatReadDirection = .older,
              nextFrame: NextFrame, scroll: Scroll) async throws -> ChatEvidenceSession {
        try await read(request: request, direction: direction, nextObservation: {
            do { return .frame(try await nextFrame()) }
            catch let error as ChatUnmergedCaptureError { return .unmerged(error.observation) }
        }, scroll: scroll)
    }

    @discardableResult
    func read(request: ChatReadRequest, direction: ChatReadDirection = .older,
              nextObservation: NextObservation, scroll: Scroll) async throws -> ChatEvidenceSession {
        try Task.checkCancellation()
        if case .currentPage = request.range, direction != .older { throw ChatEvidenceError.invalidRequest }
        let scopeAlreadyExisted = store.sessions.contains { $0.id == request.scopeID }
        var session = try store.prepare(request)
        if case .latest = request.range {
            // Preserve old evidence/reports byte-for-byte on a rejected retry.
            // Only a newly empty scope records the unsupported result.
            if !scopeAlreadyExisted {
                session.state = .partial; session.detail = "latestEndUnknown：" + ChatEvidenceError.latestEndUnknown.localizedDescription
                try store.save(session)
            }
            throw ChatEvidenceError.latestEndUnknown
        }
        if case .currentPage = request.range {
            guard session.pageSelection == nil, session.frames.isEmpty, session.messages.isEmpty else { throw ChatEvidenceError.pageAlreadyBound }
        }
        session.state = .reading; session.detail = "按指定会话与范围读取；尚未完成"
        try store.save(session)
        // Coverage is established by this fresh run, never inherited from an
        // old complete state or legacy OCR occurrence associations.
        var startSideWitness = false, firstAcceptedFrame = true
        do {
            for pageIndex in 0..<request.maxPages {
                try Task.checkCancellation()
                guard session.frames.count + (session.unmergedBatches?.count ?? 0) < 300 else { throw ChatEvidenceError.limit }
                let observation = try await nextObservation()
                try Task.checkCancellation()
                let frame: ChatEvidenceFrame
                switch observation {
                case let .unmerged(raw):
                    try archive(raw, session: &session, direction: direction)
                    throw ChatEvidenceError.ambiguousContinuity
                case let .frame(value): frame = value
                }
                // Legacy proofs remain decodable, but cannot authorize a new
                // live read. Retain the rejected observation without its proof.
                if frame.conversation.kind == .controlledScroll {
                    try archive(.init(id: frame.id, snapshot: frame.snapshot, rows: frame.rows,
                        captureSessionID: frame.captureSessionID, reason: .unverifiedConversationContinuity), session: &session, direction: direction)
                    throw ChatEvidenceError.ambiguousContinuity
                }
                try frame.validate(for: request.conversation)
                guard session.frames.last.map({ $0.snapshot.capturedAt < frame.snapshot.capturedAt }) ?? true else { throw ChatEvidenceError.invalidFrame }
                guard !session.frames.contains(where: { $0.id == frame.id }) else { throw ChatEvidenceError.invalidFrame }
                let previousCount = session.messages.count
                var accepted = session
                do { try Self.merge(frame: frame, into: &accepted, direction: direction) }
                catch {
                    // Merging is transactional: failed candidates cannot add
                    // guessed anchors to the previously accepted messages.
                    try archive(.init(id: frame.id, snapshot: frame.snapshot, rows: frame.rows,
                        captureSessionID: frame.captureSessionID, reason: .unverifiedOccurrenceContinuity), session: &session, direction: direction)
                    throw error
                }
                accepted.frames.append(frame); session = accepted
                session.updatedAt = Date()
                if case let .currentPage(limit) = request.range {
                    session.pageSelection = .init(scopeID: session.id, requestedConversation: request.conversation,
                        frameID: frame.id, capturedAt: frame.snapshot.capturedAt, limit: limit,
                        messageIDs: Array(session.messages.suffix(limit)).map(\.id))
                    session.state = .complete
                    session.detail = "已固定首次可见页：观察 \(session.messages.count) 条，选定 \(session.selectedMessages.count) 条已识别消息；这是本页样本，不证明会话最近端或完整媒介"
                    try store.save(session); return session
                }
                if firstAcceptedFrame {
                    if case let .time(start, end) = request.range {
                        let known = frame.rows.compactMap(\.sentAt)
                        startSideWitness = direction == .older ? known.contains(where: { $0 > end }) : known.contains(where: { $0 < start })
                    }
                    firstAcceptedFrame = false
                }
                if Self.rangeCovered(session: session, frame: frame, direction: direction, startSideWitness: startSideWitness) {
                    session.state = .complete
                    session.detail = "已读取指定条数或已验证范围两侧覆盖"
                    try store.save(session); return session
                }
                if frame.reachedBoundary {
                    session.state = .partial
                    session.detail = "已到本方向历史边界；范围两侧、未知时间或时间顺序仍未通过核验，未标记完整"
                    try store.save(session); return session
                }
                if session.messages.count == previousCount {
                    session.state = .partial; session.detail = "画面无新增消息且范围覆盖未验证，停止滚动并保留检查点"
                    try store.save(session); return session
                }
                try store.save(session) // durable checkpoint BEFORE a scroll
                guard pageIndex + 1 < request.maxPages,
                      session.frames.count + (session.unmergedBatches?.count ?? 0) < 300 else { break }
                try Task.checkCancellation()
                try await scroll(direction)
            }
            session.state = .partial; session.detail = "达到本次分页或原始证据上限；未证明完整范围，已保存证据且未再滚动"
            session.updatedAt = Date(); try store.save(session); return session
        } catch {
            if session.state != .ambiguous {
                session.state = error is CancellationError ? .partial : .stopped
                session.detail = error is CancellationError ? "读取中断，已保存最后一个完整批次，未标记范围完成" : (error as? ChatEvidenceError)?.localizedDescription ?? "读取或滚动失败，已保存检查点"
                session.updatedAt = Date(); try? store.save(session)
            }
            throw error
        }
    }

    private func archive(_ raw: ChatUnmergedObservation, session: inout ChatEvidenceSession, direction: ChatReadDirection) throws {
        guard let source = session.frames.last else { throw ChatEvidenceError.wrongConversation }
        let batch = ChatUnmergedBatch(id: raw.id, snapshot: raw.snapshot, rows: raw.rows,
            captureSessionID: raw.captureSessionID, scopeID: session.id,
            requestedConversation: session.request.conversation, direction: direction, reason: raw.reason, sourceFrameID: source.id)
        var retained = session
        retained.unmergedBatches = (retained.unmergedBatches ?? []) + [batch]
        retained.state = .ambiguous
        retained.detail = "会话延续或消息发生位置未独立验证；原始未合并批次已保留，未计入消息或引用。本地 OCR 没有真实消息 ID，当前仅支持可独立核验的一页读取"
        retained.updatedAt = Date()
        try store.save(retained)
        session = retained
    }

    private static func rangeCovered(session: ChatEvidenceSession, frame: ChatEvidenceFrame, direction: ChatReadDirection, startSideWitness: Bool) -> Bool {
        switch session.request.range {
        case .latest, .currentPage: return false
        case let .time(start, end):
            guard startSideWitness, !session.messages.isEmpty, session.unreadTimeMessageIDs.isEmpty,
                  !session.knownTimeOrderConflict else { return false }
            // An undirected reachedBoundary flag proves neither both edges nor
            // messages sharing an endpoint timestamp. Require strict witnesses.
            return direction == .older ? frame.rows.contains(where: { $0.sentAt.map { $0 < start } ?? false }) : frame.rows.contains(where: { $0.sentAt.map { $0 > end } ?? false })
        }
    }

    static func merge(frame: ChatEvidenceFrame, into session: inout ChatEvidenceSession, direction: ChatReadDirection) throws {
        if session.messages.isEmpty {
            session.messages = frame.rows.map { .init(id: "m-" + UUID().uuidString.lowercased(), observation: $0, anchors: [$0.anchor]) }
            return
        }
        guard !frame.rows.isEmpty else {
            if frame.reachedBoundary { return }
            throw ChatEvidenceError.ambiguousContinuity
        }
        let old = session.messages.map(\.observation), incoming = frame.rows
        let overlap = try ChatMessageContinuity.verifiedOccurrenceOverlap(existing: old, incoming: incoming, direction: direction)
        try attach(incoming, overlap: overlap, into: &session, direction: direction)
    }

    private static func attach(_ incoming: [ChatObservedMessage], overlap: Int, into session: inout ChatEvidenceSession, direction: ChatReadDirection) throws {
        let overlapRows = direction == .newer ? Array(incoming.prefix(overlap)) : Array(incoming.suffix(overlap))
        let oldStart = direction == .newer ? session.messages.count - overlap : 0
        for offset in overlapRows.indices {
            let anchor = overlapRows[offset].anchor
            if !session.messages[oldStart + offset].anchors.contains(anchor) { session.messages[oldStart + offset].anchors.append(anchor) }
        }
        let newRows = direction == .newer ? Array(incoming.dropFirst(overlap)) : Array(incoming.dropLast(overlap))
        let existingIDs = Set(session.messages.compactMap { $0.observation.platformMessageID })
        guard newRows.allSatisfy({ $0.platformMessageID.map { !existingIDs.contains($0) } ?? true }),
              session.messages.count + newRows.count <= 10_000 else { throw ChatEvidenceError.ambiguousContinuity }
        let added = newRows.map { ChatEvidenceMessage(id: "m-" + UUID().uuidString.lowercased(), observation: $0, anchors: [$0.anchor]) }
        if direction == .newer { session.messages += added } else { session.messages = added + session.messages }
    }
}

/// Ephemeral authority for one live capture run. Never persist or reuse this
/// object across readChat calls, navigation, refresh or a restored checkpoint.
/// The first frame must independently prove the stable conversation. Only a
/// successful wrapped scroll permits exactly one subsequent observation. OCR
/// without independent message IDs yields raw evidence, never live authority.
@MainActor
final class ChatEvidenceCaptureAdapter {
    private struct LiveBootstrap { var frame: ChatEvidenceFrame; var issuedAt: Date }
    private static var liveBootstraps: [String: LiveBootstrap] = [:]
    private var previous: ChatEvidenceFrame?
    private var captureID: UUID?
    private var pendingScroll: ChatReadDirection?
    private var scrolling = false

    /// Called only by the live profile/navigation driver after its real reads
    /// and input return. It is deliberately absent from Codable evidence.
    static func authorizeLiveBootstrap(_ frame: ChatEvidenceFrame) {
        let now = Date()
        liveBootstraps = liveBootstraps.filter { (0..<30).contains(now.timeIntervalSince($0.value.issuedAt)) }
        if liveBootstraps.count >= 32, let oldest = liveBootstraps.min(by: { $0.value.issuedAt < $1.value.issuedAt })?.key { liveBootstraps.removeValue(forKey: oldest) }
        liveBootstraps[frame.id] = .init(frame: frame, issuedAt: now)
    }

    /// A live profile-to-chat driver can seed this fresh adapter exactly once.
    /// Persisted continuation frames and naked titles cannot seed authority.
    @discardableResult
    func begin(bootstrap: ChatEvidenceFrame, target: ChatConversationTarget) throws -> ChatEvidenceFrame {
        let live = Self.liveBootstraps.removeValue(forKey: bootstrap.id)
        guard previous == nil, captureID == nil, pendingScroll == nil, !scrolling,
              bootstrap.captureSessionID != nil,
              live?.frame == bootstrap, live.map({ (0..<30).contains(Date().timeIntervalSince($0.issuedAt)) }) == true,
              [.builtInTransfer, .contactProfileNavigation].contains(bootstrap.conversation.kind) else {
            invalidate(); throw ChatEvidenceError.wrongConversation
        }
        do { try bootstrap.validate(for: target) }
        catch { invalidate(); throw error }
        previous = bootstrap; captureID = bootstrap.captureSessionID
        return bootstrap
    }

    func frame(snapshot: PhoneUISnapshot, captureSessionID: UUID, id: String,
               reachedBoundary: Bool = false, timeZone: TimeZone = .current) throws -> ChatEvidenceFrame {
        switch try observation(snapshot: snapshot, captureSessionID: captureSessionID, id: id, reachedBoundary: reachedBoundary, timeZone: timeZone) {
        case let .frame(frame): return frame
        case let .unmerged(raw): throw ChatUnmergedCaptureError(observation: raw)
        }
    }

    func observation(snapshot: PhoneUISnapshot, captureSessionID: UUID, id: String,
                     reachedBoundary: Bool = false, timeZone: TimeZone = .current) throws -> ChatEvidenceObservation {
        guard !scrolling else { invalidate(); throw ChatEvidenceError.wrongConversation }
        do {
            if let captureID, captureID != captureSessionID { throw ChatEvidenceError.wrongConversation }
            if let previous, pendingScroll != nil {
                guard snapshot.deviceKey == previous.snapshot.deviceKey,
                      snapshot.capturedAt > previous.snapshot.capturedAt,
                      !snapshot.blockingOverlay,
                      let page = WeChatContactIdentity.chatPage(snapshot: snapshot, title: previous.conversation.title) else { throw ChatEvidenceError.wrongConversation }
                let rows = ChatEvidenceFrame.observedRows(snapshot: snapshot, id: id, page: page,
                    excluding: PhonePageAdapters.selfTransferEvidence(in: snapshot).map { [$0.id] } ?? [], timeZone: timeZone)
                // Even a locally unique AB pair may be a different repeated
                // pair. Preserve pixels/OCR, but revoke authority immediately.
                let raw = ChatUnmergedObservation(id: id, snapshot: snapshot, rows: rows,
                    captureSessionID: captureSessionID, reason: .unverifiedConversationContinuity)
                invalidate()
                return .unmerged(raw)
            }
            // Refresh/new run always requires independent evidence again.
            let result = try ChatEvidenceFrame.from(snapshot: snapshot, id: id, reachedBoundary: reachedBoundary, timeZone: timeZone)
            var tagged = result; tagged.captureSessionID = captureSessionID
            self.captureID = captureSessionID; self.previous = tagged; pendingScroll = nil
            return .frame(tagged)
        } catch { invalidate(); throw error }
    }

    func scroll(_ direction: ChatReadDirection, perform: (ChatReadDirection) async throws -> Void) async throws {
        guard let previous, captureID != nil, pendingScroll == nil, !scrolling else {
            invalidate(); throw ChatEvidenceError.wrongConversation
        }
        scrolling = true
        defer { scrolling = false }
        do {
            try Task.checkCancellation()
            try await perform(direction)
            try Task.checkCancellation()
            guard self.previous?.id == previous.id, captureID == previous.captureSessionID else { throw ChatEvidenceError.wrongConversation }
            pendingScroll = direction
        } catch { invalidate(); throw error }
    }

    /// Navigation/refresh handlers may explicitly revoke the current chain.
    func invalidate() { previous = nil; captureID = nil; pendingScroll = nil }
}
