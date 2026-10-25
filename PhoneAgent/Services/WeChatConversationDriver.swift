import Foundation

struct WeChatConversationObservation {
    var snapshot: PhoneUISnapshot
    var captureSessionID: UUID
    var frameID: String
    var confirmedAt: Date? = nil
}

/// Production navigation using only fresh host OCR and observed controls.
/// The caller supplies the existing PhoneWorkflowCaptureDriver's read/tap/
/// scroll operations; a model never supplies an observation or coordinate.
@MainActor
final class WeChatConversationDriver {
    typealias Read = () async throws -> WeChatConversationObservation
    typealias Tap = (PhoneUIElement) async throws -> Void
    typealias Scroll = (ChatReadDirection) async throws -> Void
    private let readObservation: Read
    private let tap: Tap
    private let performScroll: Scroll
    private let now: () -> Date
    private var opening = false

    init(read: @escaping Read, tap: @escaping Tap, scroll: @escaping Scroll, now: @escaping () -> Date = Date.init) {
        self.readObservation = read; self.tap = tap; self.performScroll = scroll; self.now = now
    }

    /// The user opens the personal profile themselves. This method never
    /// searches contacts or chooses a display-name match. One observed button
    /// is tapped once; interrupted navigation is never replayed in this run.
    func bootstrap(target: ChatConversationTarget) async throws -> ChatEvidenceFrame {
        guard !opening else { throw ChatEvidenceError.wrongConversation }
        opening = true
        defer { opening = false }
        try ChatReadRequest(scopeID: "contact-bootstrap", conversation: target, range: .currentPage(limit: 1), maxPages: 1).validate()
        let builtIn = PhonePageAdapters.canonicalConversation(target.title) == target.stableID
        if !builtIn { _ = try WeChatContactIdentity.account(fromStableID: target.stableID) }
        try Task.checkCancellation()
        let initial = try await readObservation()
        try Task.checkCancellation()
        guard initial.snapshot.deviceKey == target.deviceKey else { throw ChatEvidenceError.wrongConversation }
        if builtIn, var result = try? ChatEvidenceFrame.from(snapshot: initial.snapshot, id: initial.frameID) {
            result.captureSessionID = initial.captureSessionID
            try result.validate(for: target)
            ChatEvidenceCaptureAdapter.authorizeLiveBootstrap(result)
            return result
        }
        let profile = try WeChatContactIdentity.profile(snapshot: initial.snapshot, frameID: initial.frameID,
            captureSessionID: initial.captureSessionID, target: target, confirmedAt: initial.confirmedAt)
        guard let message = initial.snapshot.element(id: profile.messageElementID) else { throw ChatEvidenceError.wrongConversation }
        let started = now()
        guard initial.snapshot.capturedAt <= started, initial.confirmedAt.map({ $0 <= started }) ?? true else { throw ChatEvidenceError.invalidFrame }
        try Task.checkCancellation()
        try await tap(message) // exactly one actual, current OCR element
        try Task.checkCancellation()
        let completed = now()
        var navigation = WeChatContactNavigationEvidence(profile: profile, tapStartedAt: started, tapCompletedAt: completed)
        var previousConfirmation = initial.confirmedAt ?? initial.snapshot.capturedAt
        // The transition may still expose the same profile briefly. Reobserve
        // at most three real fresh frames, without issuing another tap.
        for _ in 0..<3 {
            let observation = try await readObservation()
            try Task.checkCancellation()
            guard observation.captureSessionID == initial.captureSessionID,
                  observation.snapshot.deviceKey == target.deviceKey,
                  (observation.confirmedAt ?? observation.snapshot.capturedAt) > previousConfirmation,
                  (observation.confirmedAt ?? observation.snapshot.capturedAt) >= observation.snapshot.capturedAt,
                  !observation.snapshot.blockingOverlay else { throw ChatEvidenceError.wrongConversation }
            previousConfirmation = observation.confirmedAt ?? observation.snapshot.capturedAt
            if WeChatContactIdentity.chatPage(snapshot: observation.snapshot, title: target.title) != nil {
                navigation.chatConfirmedAt = observation.confirmedAt ?? observation.snapshot.capturedAt
                let result = try ChatEvidenceFrame.fromContactNavigation(snapshot: observation.snapshot, id: observation.frameID,
                    captureSessionID: observation.captureSessionID, target: target, navigation: navigation)
                ChatEvidenceCaptureAdapter.authorizeLiveBootstrap(result)
                return result
            }
            // Only the very same independently reverified profile may be a
            // pending transition. Another page/account terminates immediately.
            _ = try WeChatContactIdentity.profile(snapshot: observation.snapshot, frameID: observation.frameID,
                captureSessionID: observation.captureSessionID, target: target, confirmedAt: observation.confirmedAt)
        }
        throw ChatEvidenceError.invalidFrame
    }

    func open(target: ChatConversationTarget) async throws -> ChatEvidenceFrame { try await bootstrap(target: target) }

    @discardableResult
    func read(request: ChatReadRequest, store suppliedStore: ChatEvidenceStore? = nil,
              direction: ChatReadDirection = .older) async throws -> ChatEvidenceSession {
        let store = suppliedStore ?? .shared
        try Task.checkCancellation()
        if case .latest = request.range {
            // Unsupported latest-end authority is rejected before profile reads
            // or navigation, including retries of legacy saved complete scopes.
            return try await ChatEvidenceReader(store: store).read(request: request, direction: direction,
                nextFrame: { throw ChatEvidenceError.latestEndUnknown }, scroll: { _ in throw ChatEvidenceError.latestEndUnknown })
        }
        if case .currentPage = request.range {
            guard direction == .older else { throw ChatEvidenceError.invalidRequest }
            if let prior = store.sessions.first(where: { $0.id == request.scopeID }),
               prior.pageSelection != nil || !prior.frames.isEmpty || !prior.messages.isEmpty { throw ChatEvidenceError.pageAlreadyBound }
        }
        _ = try store.prepare(request) // bind scope BEFORE any navigation input
        let first: ChatEvidenceFrame
        do { first = try await bootstrap(target: request.conversation) }
        catch {
            var session = try store.session(id: request.scopeID)
            session.state = error is CancellationError ? .partial : .stopped
            session.detail = error is CancellationError ? "资料到会话导航已取消；恢复需要重新证明账号，未自动重放点击" : "资料账号或受控导航未通过核验，未读取聊天消息"
            session.updatedAt = now(); try? store.save(session)
            throw error
        }
        let adapter = ChatEvidenceCaptureAdapter()
        _ = try adapter.begin(bootstrap: first, target: request.conversation)
        var pendingFirst: ChatEvidenceFrame? = first
        return try await ChatEvidenceReader(store: store).read(request: request, direction: direction, nextObservation: {
            if let initial = pendingFirst { pendingFirst = nil; return .frame(initial) }
            let observation = try await self.readObservation()
            return try adapter.observation(snapshot: observation.snapshot, captureSessionID: observation.captureSessionID, id: observation.frameID)
        }, scroll: { direction in try await adapter.scroll(direction, perform: self.performScroll) })
    }
}
