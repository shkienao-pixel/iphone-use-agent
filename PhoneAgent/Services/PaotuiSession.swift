import Foundation

enum PaotuiSessionOrigin: Hashable {
    case conversation(UUID)
    case task(UUID)
    case workbench

    var conversationID: UUID? { if case .conversation(let id) = self { return id }; return nil }
    var isQueryOnly: Bool { if case .conversation = self { return false }; return true }
}

/// The single mutable owner of one preparation. Adapters may hold a temporary
/// value snapshot, but every update returns through this versioned authority.
@MainActor final class PaotuiSession {
    struct Preparation: Equatable {
        var draft = PaotuiDraft()
        var keyword = ""
        var city = ""
        var recipientKeyword = ""
        var senderKeyword = ""
        var inquiryOnly = false
        var addressOffset = 0
    }
    enum ReadOperation: Equatable { case addresses, places, quote, status }
    struct ReadRecovery: Equatable {
        let operation: ReadOperation
        let canRetry: Bool
        let message: String
    }
    enum Outcome: Equatable { case created, notDispatched, unknown }
    enum Phase: Equatable {
        case collecting([PaotuiMissingField])
        case clarifying
        case readyForReview
        case reading(ReadOperation)
        case quoted
        case awaitingConfirmation(quoteID: UUID, extraFeeAcknowledged: Bool)
        case submitting(quoteID: UUID)
        case outcome(quoteID: UUID, Outcome)
        case readFailed(ReadRecovery)
        case closed
    }
    struct Ticket: Equatable {
        let sessionID: UUID
        let origin: PaotuiSessionOrigin
        let revision: UInt64
        let authorizationEpoch: UUID
        fileprivate init(sessionID: UUID, origin: PaotuiSessionOrigin, revision: UInt64, authorizationEpoch: UUID) {
            self.sessionID = sessionID; self.origin = origin; self.revision = revision; self.authorizationEpoch = authorizationEpoch
        }
    }
    struct ReadTicket: Equatable {
        let request: Ticket
        let operation: ReadOperation
        fileprivate let id: UUID
        fileprivate let pricingRevision: UInt64
    }
    struct SubmissionGrant: Equatable {
        let request: Ticket
        let quoteID: UUID
        fileprivate let id: UUID
    }
    enum SessionError: LocalizedError {
        case stale, invalidCard, invalidQuote, invalidReference, queryOnly, missingConfirmation, staleRead
        var errorDescription: String? {
            switch self {
            case .stale: "本次跑腿需求或授权已改变，请使用当前对话继续"
            case .invalidCard: "这张卡片已失效或内容不匹配，请使用当前对话中的卡片"
            case .invalidQuote: "报价或订单状态已改变，请重新查询费用"
            case .invalidReference: "美团地址结果包含重复引用，请重新查询后选择"
            case .queryOnly: "此入口只允许查询与询价，不能创建订单"
            case .missingConfirmation: "请在当前有效的订单确认卡片明确确认"
            case .staleRead: "本次读取已过时，请根据当前需求重新查询"
            }
        }
    }

    let sessionID = UUID()
    let origin: PaotuiSessionOrigin
    let authorizationEpoch: UUID
    let credentialScope: String
    private(set) var revision: UInt64 = 0
    private(set) var preparation = Preparation()
    private(set) var phase: Phase = .collecting([.service, .goods, .recipient])
    private(set) var quotes: [PaotuiQuote] = []
    private(set) var selectedQuoteID: UUID?
    private(set) var highFeeAcknowledgedQuoteID: UUID?
    private(set) var currentCard: PaotuiChatCard?
    private(set) var isActive = true
    private var offeredTicket: Ticket?
    private var consumedCard: PaotuiChatCard?
    private var consumedTicket: Ticket?
    private var activeRead: ReadTicket?
    private var pricingRevision: UInt64 = 0
    private var activeGrant: SubmissionGrant?
    private var placeRecords: [String: PaotuiAddress] = [:]
    private var latestPlaceIDs: [String] = []
    private var issuedQueryReferences: Set<String> = []
    /// Recovery is a new authority instance. Retained references are evidence
    /// only until this instance has fetched the current address book; neither
    /// they nor a saved history card are restored as selections.
    private(set) var restoredSavedAddressReferences: Set<String> = []
    private(set) var revalidatedSavedAddressReferences: Set<String> = []
    private(set) var requiresAddressRefresh = false
    var onChange: (() -> Void)?

    init(origin: PaotuiSessionOrigin, authorizationEpoch: UUID, credentialScope: String) {
        self.origin = origin; self.authorizationEpoch = authorizationEpoch; self.credentialScope = credentialScope
        if origin.isQueryOnly { preparation.inquiryOnly = true }
    }

    var ticket: Ticket { Ticket(sessionID: sessionID, origin: origin, revision: revision, authorizationEpoch: authorizationEpoch) }
    var draft: PaotuiDraft { preparation.draft }
    var places: [PaotuiAddress] { latestPlaceIDs.compactMap { placeRecords[$0] } }
    var verifiedPlaces: [PaotuiAddress] { placeRecords.values.sorted { $0.id < $1.id } }
    var readRecovery: ReadRecovery? { if case .readFailed(let recovery) = phase { return recovery }; return nil }
    var hasInFlightOperation: Bool { activeRead != nil || activeGrant != nil || { if case .submitting = phase { return true }; return false }() }
    var hasPreparation: Bool { preparation != Preparation() }
    func restoreForReview(_ snapshot: PaotuiPreparationSnapshot) throws {
        guard snapshot.conversationID == origin.conversationID, snapshot.credentialFingerprint == credentialScope else { throw SessionError.stale }
        try replacePreparation(snapshot.preparationForReview)
        restoredSavedAddressReferences = Set([snapshot.savedRecipientReference, snapshot.savedSenderReference].compactMap { $0 })
        revalidatedSavedAddressReferences = []; requiresAddressRefresh = true
        onChange?()
    }
    func revalidateRestoredAddressReferences(in addresses: [PaotuiAddress]) {
        guard requiresAddressRefresh else { return }
        let current = Set(addresses.filter { $0.savedID != nil }.map(\.id))
        revalidatedSavedAddressReferences = restoredSavedAddressReferences.intersection(current)
        requiresAddressRefresh = false
        // Selection still requires an explicit choice from current results.
        onChange?()
    }
    func recordQueryReferences(_ references: Set<String>) {
        guard isActive, origin.isQueryOnly else { return }
        issuedQueryReferences.formUnion(references)
    }
    func hasQueryReference(_ reference: String) -> Bool {
        isActive && issuedQueryReferences.contains(reference)
    }
    func invalidateQueryReferences(_ references: Set<String>) {
        issuedQueryReferences.subtract(references)
    }

    func validate(_ expected: Ticket) throws {
        try Task.checkCancellation()
        guard matches(expected) else { throw SessionError.stale }
    }
    /// Core result settlement must not depend on the caller's UI task surviving.
    func matches(_ expected: Ticket) -> Bool { isActive && expected == ticket }
    @discardableResult
    func beginTurn() throws -> Ticket {
        guard isActive else { throw SessionError.stale }
        revision &+= 1
        revokePricing(); activeRead = nil; revokeCard(); activeGrant = nil
        phase = preparationPhase()
        onChange?()
        return ticket
    }
    func replacePreparation(_ value: Preparation, expected: Ticket? = nil) throws {
        if let expected { try validate(expected) }
        guard isActive else { throw SessionError.stale }
        var value = value
        if origin.isQueryOnly { value.inquiryOnly = true }
        guard value != preparation else { return }
        preparation = value; revision &+= 1
        revokePricing(); activeRead = nil; revokeCard(); activeGrant = nil
        phase = preparationPhase()
        onChange?()
    }
    func replaceDraft(_ value: PaotuiDraft, expected: Ticket? = nil) throws {
        var updated = preparation; updated.draft = value
        try replacePreparation(updated, expected: expected)
    }
    func close() {
        isActive = false; revision &+= 1
        issuedQueryReferences = []
        revokePricing(); revokeCard(); activeRead = nil; activeGrant = nil
        phase = .closed
        onChange?()
    }
    func invalidatePricing() {
        guard isActive else { return }
        let hadPriceCard = currentCard?.quoteID != nil
        revokePricing()
        if activeRead?.operation == .quote { activeRead = nil }
        if hadPriceCard { revokeCard() }
        if case .submitting = phase { /* A dispatched attempt remains independent. */ }
        else if activeRead == nil { phase = preparationPhase() }
        onChange?()
    }

    func beginRead(_ operation: ReadOperation, expected: Ticket) throws -> ReadTicket {
        try validate(expected)
        if operation == .quote {
            _ = try draft.validated()
            revokePricing(); revokeCard()
        }
        let read = ReadTicket(request: ticket, operation: operation, id: UUID(), pricingRevision: pricingRevision)
        activeRead = read; phase = .reading(operation)
        onChange?()
        return read
    }
    func validateRead(_ expected: ReadTicket) throws {
        try validate(expected.request)
        guard activeRead == expected,
              expected.operation != .quote || expected.pricingRevision == pricingRevision else { throw SessionError.staleRead }
    }
    func completeRead(_ read: ReadTicket) throws {
        try validateRead(read)
        guard read.operation == .addresses || read.operation == .status else { throw SessionError.staleRead }
        activeRead = nil; phase = preparationPhase(); onChange?()
    }
    func acceptPlaces(_ values: [PaotuiAddress], for read: ReadTicket) throws {
        try validateRead(read)
        guard read.operation == .places else { throw SessionError.staleRead }
        guard Set(values.map(\.id)).count == values.count else { throw SessionError.invalidReference }
        for value in values {
            if placeRecords[value.id] != value { issuedQueryReferences.remove(value.id) }
            placeRecords[value.id] = value
        }
        latestPlaceIDs = values.map(\.id)
        if placeRecords.count > 200 {
            let preserved = Set(latestPlaceIDs + [draft.senderID])
            for key in placeRecords.keys.sorted() where placeRecords.count > 200 && !preserved.contains(key) {
                placeRecords.removeValue(forKey: key); issuedQueryReferences.remove(key)
            }
        }
        activeRead = nil; phase = preparationPhase(); onChange?()
    }
    func acceptQuotes(_ values: [PaotuiQuote], for read: ReadTicket) throws {
        try validateRead(read)
        guard read.operation == .quote, values.allSatisfy({ $0.draft == draft && $0.account == credentialScope }) else {
            throw SessionError.invalidQuote
        }
        quotes = values; selectedQuoteID = nil; highFeeAcknowledgedQuoteID = nil
        activeRead = nil; phase = .quoted; onChange?()
    }
    func failRead(_ read: ReadTicket, error: Error) {
        guard isActive, read.request == ticket, activeRead == read,
              read.operation != .quote || read.pricingRevision == pricingRevision else { return }
        activeRead = nil
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            phase = preparationPhase(); onChange?(); return
        }
        let retry = error is URLError
        let message = (error as? LocalizedError)?.errorDescription ?? (retry ? "暂时无法连接美团，请稍后重新查询。" : "请核对本次需求后再查询。")
        phase = .readFailed(ReadRecovery(operation: read.operation, canRetry: retry, message: message))
        onChange?()
    }
    func clearRecovery() throws {
        guard isActive else { throw SessionError.stale }
        phase = preparationPhase(); onChange?()
    }
    func markClarifying() {
        guard isActive else { return }
        if readRecovery == nil { phase = .clarifying; onChange?() }
    }

    func canonicalQuote(_ id: UUID) -> PaotuiQuote? { quotes.first { $0.id == id } }
    func owns(_ quote: PaotuiQuote) -> Bool {
        isActive && quote.account == credentialScope && quote.draft == draft && canonicalQuote(quote.id) != nil
    }
    @discardableResult
    func chooseQuote(_ id: UUID, at now: Date) throws -> PaotuiQuote {
        guard let quote = canonicalQuote(id), owns(quote), !quote.isExpired(at: now) else { throw SessionError.invalidQuote }
        selectedQuoteID = id; highFeeAcknowledgedQuoteID = nil; revokeCard()
        phase = .awaitingConfirmation(quoteID: id, extraFeeAcknowledged: false); onChange?()
        return quote
    }
    func requireHighFeeAcknowledgement(quoteID: UUID) throws {
        guard selectedQuoteID == quoteID, canonicalQuote(quoteID) != nil, !origin.isQueryOnly else { throw SessionError.invalidQuote }
        highFeeAcknowledgedQuoteID = quoteID
        phase = .awaitingConfirmation(quoteID: quoteID, extraFeeAcknowledged: true); onChange?()
    }
    func canReview(_ quote: PaotuiQuote, at now: Date, unresolved: Bool) -> Bool {
        activeGrant == nil && quoteEligible(quote.id, at: now, unresolved: unresolved)
    }
    private func quoteEligible(_ id: UUID, at now: Date, unresolved: Bool) -> Bool {
        guard !requiresAddressRefresh, !origin.isQueryOnly, !preparation.inquiryOnly, let canonical = canonicalQuote(id), owns(canonical) else { return false }
        return canonical.canSubmit(draft: draft, account: credentialScope, unresolved: unresolved, now: now)
    }
    @discardableResult
    func offer(_ card: PaotuiChatCard) throws -> PaotuiChatCard {
        guard isActive, card.valid, card.conversationID == origin.conversationID else { throw SessionError.invalidCard }
        if card.kind == "confirm" {
            guard !origin.isQueryOnly, card.quoteID == selectedQuoteID,
                  card.quoteID.flatMap(canonicalQuote) != nil else { throw SessionError.invalidCard }
        }
        currentCard = card; offeredTicket = ticket; consumedCard = nil; consumedTicket = nil
        onChange?()
        return card
    }
    func isCurrent(_ card: PaotuiChatCard) -> Bool {
        isActive && offeredTicket == ticket && currentCard == card
    }
    func consumeCard(_ submitted: PaotuiChatCard) throws -> PaotuiChatCard {
        guard isCurrent(submitted), let canonical = currentCard else { throw SessionError.invalidCard }
        consumedCard = canonical; consumedTicket = ticket; currentCard = nil; offeredTicket = nil
        onChange?()
        return canonical
    }
    func authorizeSubmission(quoteID: UUID, at now: Date, unresolved: Bool) throws -> SubmissionGrant {
        guard !origin.isQueryOnly else { throw SessionError.queryOnly }
        guard let quote = canonicalQuote(quoteID), canReview(quote, at: now, unresolved: unresolved) else { throw SessionError.invalidQuote }
        guard consumedTicket == ticket, consumedCard?.kind == "confirm", consumedCard?.quoteID == quoteID,
              selectedQuoteID == quoteID else { throw SessionError.missingConfirmation }
        guard let amount = quote.deliveryAmount, amount.minorUnits <= 10_000 || highFeeAcknowledgedQuoteID == quoteID else { throw SessionError.missingConfirmation }
        let grant = SubmissionGrant(request: ticket, quoteID: quoteID, id: UUID())
        activeGrant = grant; consumedCard = nil; consumedTicket = nil
        phase = .submitting(quoteID: quoteID); onChange?()
        return grant
    }
    func validateGrant(_ grant: SubmissionGrant, at now: Date, unresolved: Bool) throws {
        try validate(grant.request)
        guard activeGrant == grant, quoteEligible(grant.quoteID, at: now, unresolved: unresolved) else { throw SessionError.missingConfirmation }
    }
    func consumePricingAfterDurableAttempt(_ grant: SubmissionGrant) {
        guard activeGrant == grant else { return }
        quotes = []; selectedQuoteID = nil; highFeeAcknowledgedQuoteID = nil; currentCard = nil; offeredTicket = nil
        phase = .submitting(quoteID: grant.quoteID); onChange?()
    }
    func markOutcome(_ result: PaotuiOrderService.SubmissionResult, quoteID: UUID) {
        guard isActive, case .submitting(let currentQuoteID) = phase, currentQuoteID == quoteID else { return }
        let outcome: Outcome
        switch result { case .created: outcome = .created; case .notDispatched: outcome = .notDispatched; case .outcomeUnknown: outcome = .unknown }
        activeGrant = nil; revokePricing(); phase = .outcome(quoteID: quoteID, outcome); onChange?()
    }

    private func preparationPhase() -> Phase {
        draft.missingFields.isEmpty ? .readyForReview : .collecting(draft.missingFields)
    }
    private func revokePricing() {
        pricingRevision &+= 1; quotes = []; selectedQuoteID = nil; highFeeAcknowledgedQuoteID = nil
    }
    private func revokeCard() {
        currentCard = nil; offeredTicket = nil; consumedCard = nil; consumedTicket = nil
    }
}
