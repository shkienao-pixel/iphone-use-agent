import Foundation
import Combine

/// Application boundary over canonical preparation sessions and independent
/// connection/order services. Compatibility properties are projections only.
@MainActor final class MeituanPaotuiStore: ObservableObject {
    typealias ConversationRequest = PaotuiSession.Ticket
    private var sessions: [PaotuiSessionOrigin: PaotuiSession] = [:]
    private var sessionAccess: [PaotuiSessionOrigin: UInt64] = [:]
    private var accessSequence: UInt64 = 0
    private let sessionCapacity: Int
    private var hostRequestPins: [PaotuiSessionOrigin: [UUID: Int]] = [:]
    private var hostRequestPinCount = 0
    private let preparationRepository: PaotuiPreparationRepository?
    private var suppressedPreparationSaves: Set<PaotuiSessionOrigin> = []
    let diagnostics: PaotuiDiagnostics
    var diagnosticsSnapshot: PaotuiDiagnosticsSnapshot { diagnostics.snapshot }
    @Published private(set) var addresses: [PaotuiAddress] = []
    @Published private(set) var busy = false
    @Published private(set) var ready = false
    @Published private(set) var message = ""
    @Published private(set) var failed = false
    @Published private(set) var paymentURL: URL?
    @Published private(set) var orderStatus = ""
    private let connection: PaotuiConnection
    private var observedConnectionEpoch: UUID
    private let clock: PaotuiClock
    private let orders: PaotuiOrderService
    private let clientFactory: (String) -> MeituanPaotuiClient
    private let openURL: (URL) async -> Bool

    private var credential: String { connection.credential }
    private var account: String { connection.credentialFingerprint }
    var configured: Bool { connection.configured }
    var currentTime: Date { clock.now() }
    var chatAccount: String { account }
    var authorizationLink: URL? { connection.authorizationLink }
    var statusLabel: String { ready ? "跑腿已连接" : configured ? "跑腿待检测" : "跑腿未连接" }
    var hasUnresolvedSubmission: Bool { orders.journal.hasUnresolvedSubmission }
    var preparationRecoveryIssue: String? { preparationRepository?.issue }
    var savedPreparations: [PaotuiSavedPreparationSummary] {
        (preparationRepository?.snapshots ?? []).map {
            PaotuiSavedPreparationSummary(conversationID: $0.conversationID, savedAt: $0.savedAt,
                credentialMatches: configured && $0.credentialFingerprint == account,
                inquiryOnly: $0.inquiryOnly, serviceTitle: $0.service?.title, goods: $0.goods,
                missingFields: $0.preparationForReview.draft.missingFields.map(\.rawValue))
        }.sorted { $0.savedAt > $1.savedAt }
    }
    var activeSessionCount: Int { sessions.count }
    var orderReviewAvailable: Bool { orders.journal.isReadable && !pendingReviews.isEmpty }
    var journalMaintenanceSnapshot: PaotuiJournalMaintenanceSnapshot { orders.maintenanceSnapshot }
    @discardableResult func archiveResolvedOrders() throws -> Int {
        let count = try orders.archiveResolved()
        message = "已归档 \(count) 条已解决订单记录；待核验记录继续保留。"; failed = false
        objectWillChange.send(); return count
    }
    var pendingReviews: [PaotuiPendingReview] { orders.journal.pendingReviews(account: account, credentialEpoch: connection.epoch) }
    var lastOrderID: String? { orders.journal.lastOrderID(account: account) }
    func orderURL(quoteID: UUID) -> URL? { orders.journal.orderURL(quoteID: quoteID, account: account) }
    var chatOrderURL: URL? {
        if hasUnresolvedSubmission { return URL(string: "https://i.meituan.com/") }
        guard let id = lastOrderID else { return URL(string: "https://i.meituan.com/") }
        return URL(string: "https://i.meituan.com/order/" + id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)
    }

    // Legacy workbench accessors share the same Session implementation. Tool
    // requests use separate query-only task sessions and never mutate this one.
    var draft: PaotuiDraft {
        get { session(origin: .workbench).draft }
        set {
            do { try session(origin: .workbench).replaceDraft(newValue) }
            catch { message = error.localizedDescription; failed = true }
        }
    }
    var quotes: [PaotuiQuote] { session(origin: .workbench).quotes }
    var places: [PaotuiAddress] { session(origin: .workbench).places }
    var knownLocations: [PaotuiAddress] { addresses + session(origin: .workbench).verifiedPlaces }

    init(connection: PaotuiConnection,
         receiptURL: URL = URL.applicationSupportDirectory.appendingPathComponent("PhoneAgent/paotui-orders.json"),
         clientFactory: ((String) -> MeituanPaotuiClient)? = nil,
         commitJournal: ((URL, URL) throws -> Void)? = nil,
         preparationRepository: PaotuiPreparationRepository? = nil,
         sessionCapacity: Int = 64,
         diagnostics: PaotuiDiagnostics? = nil,
         openURL: @escaping (URL) async -> Bool = { _ in false }) {
        let clock = PaotuiClock(now: { connection.currentTime })
        let makeClient: (String) -> MeituanPaotuiClient = { credential in
            var client = clientFactory?(credential) ?? MeituanPaotuiClient(credential: credential)
            client.now = clock.now
            return client
        }
        let journal: PaotuiOrderJournal
        if let commitJournal { journal = PaotuiOrderJournal(url: receiptURL, clock: clock, commit: commitJournal) }
        else { journal = PaotuiOrderJournal(url: receiptURL, clock: clock) }
        self.connection = connection; self.clock = clock; self.clientFactory = makeClient; self.openURL = openURL
        self.preparationRepository = preparationRepository; self.sessionCapacity = max(1, sessionCapacity)
        let diagnosticSink = diagnostics ?? PaotuiDiagnostics(clock: clock)
        self.diagnostics = diagnosticSink
        observedConnectionEpoch = connection.epoch
        orders = PaotuiOrderService(journal: journal, clientFactory: makeClient, clock: clock, diagnostics: diagnosticSink)
        connection.onChange = { [weak self] in self?.connectionDidChange() }
        journal.onChange = { [weak self] in self?.objectWillChange.send() }
        orders.onChange = { [weak self] in self?.objectWillChange.send() }
        if !journal.isReadable { message = "跑腿订单记录暂时不可读，请先在美团核对已有订单"; failed = true }
    }
    private func session(origin: PaotuiSessionOrigin) -> PaotuiSession {
        if let value = sessions[origin], value.isActive, value.authorizationEpoch == connection.epoch,
           value.credentialScope == account { touch(origin); return value }
        sessions[origin]?.close()
        let value = PaotuiSession(origin: origin, authorizationEpoch: connection.epoch, credentialScope: account)
        guard makeSessionRoom() else {
            value.close(); message = "跑腿准备数量已达上限，请先结束或移除已有准备。"; failed = true
            return value
        }
        sessions[origin] = value
        attach(value); touch(origin)
        return value
    }
    private func touch(_ origin: PaotuiSessionOrigin) { accessSequence &+= 1; sessionAccess[origin] = accessSequence }
    /// Pin before the adapter can create a Session or await interpretation.
    /// Each defer releases only its own token, including superseded callers.
    func retainHostRequest(for conversationID: UUID, requestID: UUID) throws {
        guard hostRequestPinCount < sessionCapacity * 4 else { throw AgentError.message("跑腿请求正在处理中，请等待已有请求完成。") }
        let origin = PaotuiSessionOrigin.conversation(conversationID)
        hostRequestPins[origin, default: [:]][requestID, default: 0] += 1
        hostRequestPinCount += 1
    }
    func releaseHostRequest(for conversationID: UUID, requestID: UUID) {
        let origin = PaotuiSessionOrigin.conversation(conversationID)
        guard let count = hostRequestPins[origin]?[requestID], count > 0 else { return }
        if count == 1 { hostRequestPins[origin]?.removeValue(forKey: requestID) }
        else { hostRequestPins[origin]?[requestID] = count - 1 }
        hostRequestPinCount -= 1
        if hostRequestPins[origin]?.isEmpty == true { hostRequestPins.removeValue(forKey: origin) }
    }
    private func attach(_ value: PaotuiSession) {
        value.onChange = { [weak self, weak value] in
            guard let self, let value, self.sessions[value.origin] === value else { return }
            self.touch(value.origin)
            if value.isActive, !self.suppressedPreparationSaves.contains(value.origin) { self.savePreparation(value) }
            self.objectWillChange.send()
        }
    }
    private func savePreparation(_ value: PaotuiSession) {
        guard value.origin.conversationID != nil, let preparationRepository else { return }
        if let saved = preparationRepository.snapshot(for: value.origin.conversationID!),
           saved == PaotuiPreparationSnapshot(session: value, addresses: addresses, credential: credential, at: saved.savedAt) { return }
        let snapshot = PaotuiPreparationSnapshot(session: value, addresses: addresses, credential: credential, at: currentTime)
        guard snapshot.needsPreservation else {
            if preparationRepository.snapshot(for: snapshot.conversationID) != nil {
                try? preparationRepository.discard(for: snapshot.conversationID)
            }
            return
        }
        do { try preparationRepository.save(snapshot) }
        catch { /* Recovery failure is visible separately; order facts stay independent. */ }
    }
    private func makeSessionRoom() -> Bool {
        guard sessions.count >= sessionCapacity else { return true }
        let candidates = sessions.values.filter { value in
            guard !value.hasInFlightOperation, hostRequestPins[value.origin] == nil else { return false }
            if value.origin.isQueryOnly || !value.hasPreparation { return true }
            guard let id = value.origin.conversationID, let repository = preparationRepository,
                  let saved = repository.snapshot(for: id) else { return false }
            // Eviction cannot silently drop a newer requirement after a failed save.
            return saved == PaotuiPreparationSnapshot(session: value, addresses: addresses, credential: credential, at: saved.savedAt)
        }.sorted { sessionAccess[$0.origin, default: 0] < sessionAccess[$1.origin, default: 0] }
        guard let candidate = candidates.first else { return false }
        sessions.removeValue(forKey: candidate.origin); sessionAccess.removeValue(forKey: candidate.origin)
        candidate.close()
        return true
    }
    @discardableResult func restorePreparation(for conversationID: UUID) throws -> PaotuiSession {
        let span = diagnostics.start(command: .restorePreparation, phase: .recovery, context: .init(conversationID: conversationID))
        do {
            guard configured, let snapshot = preparationRepository?.snapshot(for: conversationID),
                  snapshot.credentialFingerprint == account else { throw AgentError.message("这份准备与当前授权凭据不匹配，不能恢复。请重新描述需求。") }
            guard hostRequestPins[.conversation(conversationID)] == nil else { throw AgentError.message("这次准备仍在处理，请等待结果后再恢复。") }
            if let current = sessions[.conversation(conversationID)], current.hasInFlightOperation {
                throw AgentError.message("这次准备仍在处理，请等待结果后再恢复。")
            }
            let origin = PaotuiSessionOrigin.conversation(conversationID)
            suppressedPreparationSaves.insert(origin)
            defer { suppressedPreparationSaves.remove(origin) }
            sessions.removeValue(forKey: origin)?.close(); sessionAccess.removeValue(forKey: origin)
            let value = session(for: conversationID)
            try validateSession(value)
            try value.restoreForReview(snapshot)
            // Force a fresh current-credential book fetch before any selection.
            addresses = []; ready = false
            if let span { diagnostics.finish(span, result: .succeeded) }
            objectWillChange.send(); return value
        } catch { if let span { diagnostics.finish(span, result: .rejected) }; throw error }
    }
    func discardSavedPreparation(for conversationID: UUID) throws {
        clearPreparation(for: conversationID)
        if let issue = preparationRecoveryIssue { throw AgentError.message(issue) }
    }
    func session(for conversationID: UUID) -> PaotuiSession { session(origin: .conversation(conversationID)) }
    func existingSession(for conversationID: UUID) -> PaotuiSession? { sessions[.conversation(conversationID)] }
    func diagnosticContext(for ticket: ConversationRequest, quoteID: UUID? = nil) -> PaotuiDiagnosticContext {
        var taskID: UUID?
        if case .task(let id) = ticket.origin { taskID = id }
        return .init(conversationID: ticket.origin.conversationID, sessionID: ticket.sessionID,
            revision: ticket.revision, quoteID: quoteID, credentialEpoch: ticket.authorizationEpoch, taskID: taskID)
    }
    func validateSession(_ value: PaotuiSession) throws {
        try Task.checkCancellation()
        guard configured, value.isActive, sessions[value.origin] === value,
              value.authorizationEpoch == connection.epoch, value.credentialScope == account else {
            throw PaotuiSession.SessionError.stale
        }
    }
    private func scope(_ request: ConversationRequest) throws -> PaotuiSession {
        guard let value = sessions[request.origin] else { throw PaotuiSession.SessionError.stale }
        try validateSession(value); try value.validate(request)
        return value
    }
    func isCurrent(_ request: ConversationRequest) -> Bool { (try? scope(request)) != nil }
    @discardableResult
    func beginConversationRequest(_ id: UUID, draft: PaotuiDraft) throws -> ConversationRequest {
        let value = session(for: id)
        _ = try value.beginTurn(); try value.replaceDraft(draft)
        return value.ticket
    }
    @discardableResult
    func updateConversationDraft(_ draft: PaotuiDraft, for request: ConversationRequest) throws -> ConversationRequest {
        let value = try scope(request)
        try value.replaceDraft(draft, expected: request)
        return value.ticket
    }
    func discardConversationRequest(_ request: ConversationRequest) {
        guard let value = sessions[request.origin], value.ticket == request else { return }
        sessions.removeValue(forKey: request.origin); sessionAccess.removeValue(forKey: request.origin); value.close()
    }
    func clearPreparation(for conversationID: UUID) {
        let span = diagnostics.start(command: .clearPreparation, phase: .recovery, context: .init(conversationID: conversationID))
        let origin = PaotuiSessionOrigin.conversation(conversationID)
        sessions.removeValue(forKey: origin)?.close()
        sessionAccess.removeValue(forKey: origin)
        do { try preparationRepository?.discard(for: conversationID); if let span { diagnostics.finish(span, result: .succeeded) } }
        catch { if let span { diagnostics.finish(span, result: .failed) } }
        objectWillChange.send()
    }
    func owns(_ quote: PaotuiQuote, for request: ConversationRequest) -> Bool {
        guard let value = try? scope(request) else { return false }
        return value.owns(quote)
    }
    func locations(for request: ConversationRequest) -> [PaotuiAddress] {
        guard let value = try? scope(request) else { return [] }
        return addresses + value.verifiedPlaces
    }
    func selectService(_ service: PaotuiService) {
        let value = session(origin: .workbench)
        var updated = value.preparation
        guard updated.draft.service != service else { return }
        updated.draft.service = service; updated.draft.senderID = ""; updated.draft.nearby = false
        updated.draft.weight = nil
        do { try value.replacePreparation(updated) }
        catch { message = error.localizedDescription; failed = true }
    }
    private func connectionDidChange() {
        if observedConnectionEpoch != connection.epoch {
            diagnostics.record(command: .credentialChanged, phase: .connection, result: .succeeded,
                context: .init(credentialEpoch: connection.epoch))
            observedConnectionEpoch = connection.epoch
            for value in sessions.values { value.close() }
            sessions = [:]; sessionAccess = [:]; ready = false; addresses = []; paymentURL = nil
        }
        objectWillChange.send()
    }
    func installCredential(_ value: String) throws { try connection.installCredential(value) }
    func disconnect() throws { try connection.disconnect(); message = "已断开跑腿连接"; failed = false }
    func cancelAuthorization() { connection.cancelAuthorization() }
    func startAuthorization() async {
        await perform {
            let link = try await self.connection.startAuthorization()
            self.message = "请在美团完成授权，再点“我已授权”。链接 10 分钟有效。"
            _ = await self.openURL(link)
        }
    }
    func finishAuthorization() async {
        await perform {
            guard try await self.connection.finishAuthorization() else {
                self.message = "还在等待美团确认，请完成授权后再检测。"; return
            }
            try await self.loadAddresses()
        }
    }
    private func client() throws -> MeituanPaotuiClient {
        guard configured else { throw AgentError.message("请先在工具与连接中授权美团跑腿") }
        return clientFactory(credential)
    }
    private func validate(_ read: PaotuiSession.ReadTicket, in value: PaotuiSession, key: String, epoch: UUID) throws {
        try connection.checkCredential(key, epoch: epoch)
        try validateSession(value); try value.validateRead(read)
    }
    func loadAddresses() async throws { try await loadAddresses(for: session(origin: .workbench).ticket) }
    func loadAddresses(for request: ConversationRequest) async throws {
        let value = try scope(request), read = try value.beginRead(.addresses, expected: request)
        let span = diagnostics.start(command: .readAddresses, phase: .reading, context: diagnosticContext(for: request))
        let key = credential, epoch = connection.epoch
        do {
            let result = try await client().addresses()
            try validate(read, in: value, key: key, epoch: epoch)
            guard Set(result.map(\.id)).count == result.count else { throw PaotuiSession.SessionError.invalidReference }
            if addresses != result {
                let previous = Dictionary(uniqueKeysWithValues: addresses.map { ($0.id, $0) })
                let current = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
                let changed = Set(previous.keys).union(current.keys).filter { previous[$0] != current[$0] }
                for existing in sessions.values {
                    existing.invalidatePricing(); existing.invalidateQueryReferences(Set(changed))
                }
            }
            addresses = result; ready = true
            value.revalidateRestoredAddressReferences(in: result)
            try value.completeRead(read)
            if let span { diagnostics.finish(span, result: .succeeded) }
            message = result.isEmpty ? "请先在美团保存收货地址，再返回刷新。" : "可以选择地址查询跑腿费用。"
        } catch { if let span { diagnostics.finish(span, result: error is CancellationError ? .cancelled : .failed) }; value.failRead(read, error: error); throw error }
    }
    func refresh() async { await perform { try await self.loadAddresses() } }
    func search(keyword: String, city: String) async throws {
        _ = try await search(keyword: keyword, city: city, for: session(origin: .workbench).ticket)
    }
    func searchFromUI(keyword: String, city: String) async { await perform { try await self.search(keyword: keyword, city: city) } }
    func search(keyword: String, city: String, for request: ConversationRequest) async throws -> [PaotuiAddress] {
        let value = try scope(request), read = try value.beginRead(.places, expected: request)
        let span = diagnostics.start(command: .readPlaces, phase: .reading, context: diagnosticContext(for: request))
        let key = credential, epoch = connection.epoch
        let near = addresses.first { $0.id == value.draft.recipientID }
        do {
            let result = try await client().search(keyword: keyword, city: city, near: near)
            try validate(read, in: value, key: key, epoch: epoch)
            try value.acceptPlaces(result, for: read)
            if let span { diagnostics.finish(span, result: .succeeded) }
            return result
        } catch { if let span { diagnostics.finish(span, result: error is CancellationError ? .cancelled : .failed) }; value.failRead(read, error: error); throw error }
    }
    func preview() async throws -> [PaotuiQuote] { try await preview(for: session(origin: .workbench).ticket) }
    func preview(for request: ConversationRequest) async throws -> [PaotuiQuote] {
        let value = try scope(request)
        guard !value.requiresAddressRefresh else { throw AgentError.message("恢复的准备需要先刷新并重新选择当前美团地址。") }
        let read = try value.beginRead(.quote, expected: request)
        let span = diagnostics.start(command: .requestQuote, phase: .reading, context: diagnosticContext(for: request))
        let current = try value.draft.validated(), key = credential, epoch = connection.epoch
        do {
            let result = try await preview(current, locations: addresses + value.verifiedPlaces, account: value.credentialScope,
                validate: { try self.validate(read, in: value, key: key, epoch: epoch) })
            try validate(read, in: value, key: key, epoch: epoch)
            try value.acceptQuotes(result, for: read)
            if let span { diagnostics.finish(span, result: .succeeded) }
            message = "请核对费用和地址。尚未下单。"
            return result
        } catch { if let span { diagnostics.finish(span, result: error is CancellationError ? .cancelled : .failed) }; value.failRead(read, error: error); throw error }
    }
    private func preview(_ current: PaotuiReadyRequest, locations: [PaotuiAddress], account: String,
                         validate: () throws -> Void) async throws -> [PaotuiQuote] {
        try validate()
        guard let recipient = addresses.first(where: { $0.id == current.recipientID }),
              let sender = current.nearby ? recipient : locations.first(where: { $0.id == current.senderID }) else {
            throw AgentError.message("请从本次需求的真实地址结果中选择购买／取送地址")
        }
        guard sender.cityID == recipient.cityID else { throw AgentError.message("购买／取件地址与送达地址不在同一城市，请重新选择同城地址。") }
        let results = try await client().preview(readyRequest: current, sender: sender, recipient: recipient,
            account: account, validate: validate)
        try validate()
        return results
    }
    func previewFromUI() async { await perform { _ = try await self.preview() } }
    func isCurrentWorkbenchQuote(_ quote: PaotuiQuote) -> Bool {
        let value = session(origin: .workbench)
        guard configured, value.authorizationEpoch == connection.epoch,
              let canonical = value.canonicalQuote(quote.id) else { return false }
        return value.owns(canonical) && !canonical.isExpired(at: currentTime)
    }
    func canSubmit(_ quote: PaotuiQuote, for request: ConversationRequest) -> Bool {
        guard !busy, !orders.isSubmitting, let value = try? scope(request) else { return false }
        return value.canReview(quote, at: currentTime, unresolved: hasUnresolvedSubmission)
    }
    @discardableResult
    func submitConfirmed(_ quote: PaotuiQuote, for request: ConversationRequest) async -> PaotuiOrderService.SubmissionResult {
        await submit(quoteID: quote.id, request: request)
    }
    private func submit(quoteID: UUID, request: ConversationRequest) async -> PaotuiOrderService.SubmissionResult {
        guard !busy else { return .notDispatched(message: "已有跑腿请求正在处理，请稍候") }
        let value: PaotuiSession, quote: PaotuiQuote, grant: PaotuiSession.SubmissionGrant
        do {
            value = try scope(request)
            guard let canonical = value.canonicalQuote(quoteID) else { throw PaotuiSession.SessionError.invalidQuote }
            quote = canonical
            grant = try value.authorizeSubmission(quoteID: quoteID, at: currentTime,
                unresolved: hasUnresolvedSubmission)
        } catch {
            let result = PaotuiOrderService.SubmissionResult.notDispatched(message: error.localizedDescription)
            message = result.message; failed = true; return result
        }
        busy = true; failed = false; message = ""
        defer { busy = false }
        let key = credential, epoch = connection.epoch, tag = account
        let context = PaotuiAttemptContext(sessionID: request.sessionID, conversationID: request.origin.conversationID,
            taskOrigin: nil, revision: request.revision, credentialEpoch: request.authorizationEpoch,
            quoteID: quote.id, credentialBinding: .init(credentialScope: tag))
        let result = await orders.submit(quote: quote, credential: key, account: tag, context: context, validate: {
            _ = try self.scope(request)
            try value.validateGrant(grant, at: self.currentTime, unresolved: self.hasUnresolvedSubmission)
        }, invalidate: { value.consumePricingAfterDurableAttempt(grant) })
        guard key == credential, epoch == connection.epoch,
              sessions[request.origin] === value, value.matches(request) else { return result }
        value.markOutcome(result, quoteID: quoteID)
        guard !Task.isCancelled else { return result }
        message = result.message
        switch result {
        case .created(_, let payment): paymentURL = payment; orderStatus = "订单已创建，待支付状态以美团为准。"
        case .notDispatched, .outcomeUnknown: failed = true
        }
        return result
    }
    static func paymentURL(orderID: String, trade: String, token: String) -> URL? { PaotuiOrderService.paymentURL(orderID: orderID, trade: trade, token: token) }
    func status(orderID: String) async throws -> String {
        let span = diagnostics.start(command: .readStatus, phase: .reading)
        let key = credential, epoch = connection.epoch, tag = account
        do {
            let result = try await orders.status(orderID: orderID, credential: key, account: tag,
                validateAuthorization: { try self.connection.checkCredential(key, epoch: epoch) })
            if let span { diagnostics.finish(span, result: .succeeded) }
            orderStatus = result; return result
        } catch { if let span { diagnostics.finish(span, result: error is CancellationError ? .cancelled : .failed) }; throw error }
    }
    func refreshOrder() async { await perform { if let id = self.lastOrderID { self.message = try await self.status(orderID: id) } } }
    func recordReview(attemptID: UUID, conclusion: PaotuiReviewConclusion, reportedOrderReference: String? = nil) throws {
        guard !busy else { throw AgentError.message("正在处理跑腿请求，请稍后再记录核验结果。") }
        try orders.recordReview(attemptID: attemptID, conclusion: conclusion, reportedOrderReference: reportedOrderReference)
        for value in sessions.values { value.invalidatePricing() }
        message = conclusion == .stillUnknown ? "已记录你仍无法确定结果。提交限制继续保留，请继续在美团核对。" :
            "已记录你的人工判断，尚未验证平台状态。其他待核验记录仍需逐笔处理；新订单必须重新询价并确认。"
        failed = false
    }
    private func perform(_ operation: () async throws -> Void) async {
        guard !busy else { return }; busy = true; failed = false; message = ""
        defer { busy = false }
        do { try await operation() }
        catch is CancellationError { message = "本次查询已停止" }
        catch { failed = true; message = (error as? LocalizedError)?.errorDescription ?? "网络请求未完成，请稍后重试。" }
    }
    private func query(_ input: PaotuiToolQuery, in value: PaotuiSession) async throws -> (result: PaotuiQueryResult, ticket: PaotuiSession.Ticket) {
        _ = try value.beginTurn()
        switch input.action {
        case .addresses:
            let ticket = value.ticket
            try await loadAddresses(for: ticket)
            _ = try scope(ticket)
            let filtered = addresses.filter { input.keyword?.isEmpty != false || $0.fullAddress.localizedCaseInsensitiveContains(input.keyword!) }
            return (.addresses(Array(filtered.prefix(20)), total: filtered.count, at: currentTime), ticket)
        case .search:
            guard let keyword = input.keyword, let city = input.city, !keyword.isEmpty, !city.isEmpty else { throw AgentError.message("搜索地址需要城市和关键词") }
            if let recipient = input.recipient, !value.hasQueryReference(recipient) {
                throw AgentError.message("请先在本任务查询并选择真实收货地址")
            }
            if addresses.isEmpty {
                let ticket = value.ticket
                try await loadAddresses(for: ticket)
                _ = try scope(ticket)
            }
            if let recipient = input.recipient {
                guard value.hasQueryReference(recipient), addresses.contains(where: { $0.id == recipient }) else {
                    throw AgentError.message("请先在本任务查询并选择真实收货地址")
                }
                var updated = value.preparation; updated.draft.recipientID = recipient
                try value.replacePreparation(updated)
            }
            let ticket = value.ticket
            let rows = try await search(keyword: keyword, city: city, for: ticket)
            _ = try scope(ticket)
            return (.places(Array(rows.prefix(20)), total: rows.count, at: currentTime), ticket)
        case .preview_buy, .preview_send:
            let draft = try input.validatedDraft()
            guard value.hasQueryReference(draft.recipientID),
                  draft.nearby || value.hasQueryReference(draft.senderID) else {
                throw AgentError.message("请先在本任务查询并选择真实购买／取件及送达地址")
            }
            try value.replaceDraft(draft)
            let ticket = value.ticket
            let quotes = try await preview(for: ticket)
            _ = try scope(ticket)
            return (.quotes(quotes, at: currentTime), ticket)
        case .order_status:
            guard let id = input.order_id, !id.isEmpty else { throw AgentError.message("请提供真实跑腿订单编号") }
            let read = try value.beginRead(.status, expected: value.ticket), key = credential, epoch = connection.epoch
            do {
                let result = try await status(orderID: id)
                try validate(read, in: value, key: key, epoch: epoch)
                try value.completeRead(read)
                return (.status(result, at: currentTime), read.request)
            } catch { value.failRead(read, error: error); throw error }
        }
    }
    func tool(_ query: String, taskID: UUID) async throws -> String {
        let input = try PaotuiToolQuery.decode(query)
        let value = session(origin: .task(taskID))
        let response = try await self.query(input, in: value)
        _ = try scope(response.ticket)
        let rendered = try response.result.render()
        if input.action == .addresses || input.action == .search { value.recordQueryReferences(rendered.references) }
        return rendered.json
    }
}
