import Foundation

@MainActor private final class DependencyClock {
    var instant = Date(timeIntervalSince1970: 946_684_800)
    var value: PaotuiClock { PaotuiClock(now: { self.instant }) }
}

@MainActor private final class DependencyGate {
    private var entered = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        observers.forEach { $0.resume() }; observers = []
        await withCheckedContinuation { release = $0 }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { observers.append($0) } }
    }
    func resume() { release?.resume(); release = nil }
}

/// Adds observation and one-shot gates to the existing offline provider fixture.
@MainActor private final class DependencyBackend {
    let fixture = Backend()
    var requests: [URLRequest] = []
    var gates: [String: DependencyGate] = [:]
    func client(_ credential: String) -> MeituanPaotuiClient {
        // Deliberately leave the client's default clock unchanged here. The
        // production store must propagate the connection's clock into it.
        MeituanPaotuiClient(credential: credential, transport: { request in
            self.requests.append(request)
            if let gate = self.gates.removeValue(forKey: request.url!.lastPathComponent) { await gate.hold() }
            return try self.fixture.respond(request)
        })
    }
    func pause(_ endpoint: String) -> DependencyGate {
        let gate = DependencyGate(); gates[endpoint] = gate; return gate
    }
}

@MainActor private final class DependencyCredentialStorage {
    var credential = ""
    var failSave = false
    var vault: PaotuiCredentialVault {
        PaotuiCredentialVault(read: { self.credential }, save: {
            if self.failSave { throw CocoaError(.fileWriteNoPermission) }
            self.credential = $0
        })
    }
}

@MainActor private final class DependencyScenario {
    let clock = DependencyClock()
    let backend = DependencyBackend()
    let connection: PaotuiConnection
    let store: MeituanPaotuiStore
    let controller: MeituanPaotuiConversation
    let receiptURL: URL
    let credential = "offline-dependency-credential"
    init(root: URL, storage: DependencyCredentialStorage? = nil) throws {
        receiptURL = root.appendingPathComponent(UUID().uuidString + ".json")
        if let storage {
            let blockedAuthorization = PaotuiAuthorizationGateway(
                start: { fatalError("Offline dependency fixture attempted authorization") },
                finish: { _ in fatalError("Offline dependency fixture attempted authorization") })
            connection = PaotuiConnection(vault: storage.vault, clock: clock.value, authorization: blockedAuthorization)
        } else { connection = PaotuiFixtureRuntime.connection(clock: clock.value) }
        store = MeituanPaotuiStore(connection: connection, receiptURL: receiptURL, clientFactory: backend.client)
        try store.installCredential(credential)
        controller = MeituanPaotuiConversation(store: store, planner: { question, _, _ in
            let plan: [String: Any] = ["service": "buy", "goods": question, "nearby": true, "recipient": "Fixture address 1"]
            return String(decoding: try JSONSerialization.data(withJSONObject: plan), as: UTF8.self)
        })
    }
    func globalQuote(goods: String = "Clock fixture water") async throws -> PaotuiQuote {
        if store.addresses.isEmpty { try await store.loadAddresses() }
        store.draft = PaotuiDraft(service: .buy, recipientID: "address:1", nearby: true, goods: goods)
        return try await store.preview()[0]
    }
    func scopedQuote(goods: String = "Scoped fixture water") async throws -> (MeituanPaotuiStore.ConversationRequest, PaotuiQuote) {
        if store.addresses.isEmpty { try await store.loadAddresses() }
        let request = try store.beginConversationRequest(UUID(), draft: PaotuiDraft(service: .buy, recipientID: "address:1", nearby: true, goods: goods))
        return (request, try await store.preview(for: request)[0])
    }
    func request(_ id: UUID) async throws -> PaotuiChatReply {
        try await controller.respond(question: "Conversation fixture water", history: [], conversationID: id)
    }
    func quoteCard(_ id: UUID) async throws -> PaotuiChatCard {
        let request = try await request(id)
        return try await controller.select(request.card!, .init(action: .quote), conversationID: id).card!
    }
    func confirmation(_ id: UUID) async throws -> PaotuiChatCard {
        let quote = try await quoteCard(id)
        return try await controller.select(quote, .init(action: .choose, value: quote.options[0].id), conversationID: id).card!
    }
    func receipts() throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as! [String: Any]
        return object["receipts"] as! [[String: Any]]
    }
}

@main struct PaotuiDependencyIntegrationChecks {
    private static var checks = 0
    private static func expect(_ condition: Bool, _ message: String) {
        checks += 1; precondition(condition, message)
    }
    @MainActor private static func reject(_ operation: () async throws -> Void, _ message: String) async {
        do { try await operation(); preconditionFailure(message) } catch { checks += 1 }
    }
    @MainActor private static func expectCreated(_ result: PaotuiOrderService.SubmissionResult, _ message: String) {
        guard case .created(let orderID, let payment) = result else { preconditionFailure(message) }
        expect(orderID == "fixture-order-created" && payment != nil, message)
    }
    private static func savedDate(_ value: Any?) -> Date? {
        (value as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) }
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paotui-dependencies-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // One deliberately historical clock drives HTTP, global pricing, scoped
        // pricing, native card review and the durable journal through the facade.
        let timed = try DependencyScenario(root: root), origin = timed.clock.instant
        let global = try await timed.globalQuote()
        let (scope, scoped) = try await timed.scopedQuote()
        expect(timed.connection.currentTime == origin && timed.store.currentTime == origin,
               "The facade derives its time from the injected connection clock")
        expect(global.quotedAt == origin && scoped.quotedAt == origin, "Both pricing paths use the same injected quote timestamp")
        expect(timed.store.isCurrentWorkbenchQuote(global) && timed.store.canSubmit(scoped, for: scope), "Historical quotes are valid against the injected clock")
        let expectedAjaxID = "\(Int(origin.timeIntervalSince1970 * 1000))_1532"
        let ajaxIDs = try timed.backend.requests.map {
            (try JSONSerialization.jsonObject(with: $0.httpBody!) as! [String: Any])["ajaxId"] as? String
        }
        expect(!ajaxIDs.isEmpty && ajaxIDs.allSatisfy { $0 == expectedAjaxID }, "Every actual client request inherits the connection clock")
        timed.clock.instant = origin.addingTimeInterval(299.999)
        expect(timed.store.isCurrentWorkbenchQuote(global) && timed.store.canSubmit(scoped, for: scope), "Global and scoped quotes remain valid just before five minutes")
        timed.clock.instant = origin.addingTimeInterval(300)
        expect(!timed.store.isCurrentWorkbenchQuote(global) && !timed.store.canSubmit(scoped, for: scope), "Global and scoped submission expire at exactly five minutes")

        timed.clock.instant = origin
        let chooseID = UUID(), chooseCard = try await timed.quoteCard(chooseID)
        expect(chooseCard.validUntil == origin.addingTimeInterval(300), "Conversation card expiry derives from the same quote timestamp")
        timed.clock.instant = origin.addingTimeInterval(299.999)
        let chosen = try await timed.controller.select(chooseCard, .init(action: .choose, value: chooseCard.options[0].id), conversationID: chooseID)
        expect(chosen.card?.kind == "confirm" && chosen.card?.canCreateOrder == true,
               "Native quote choice uses injected time instead of the wall clock")
        let reviewed = try await timed.controller.select(chosen.card!, .init(action: .review), conversationID: chooseID)
        expect(reviewed.card?.kind == "confirm" && reviewed.card?.canCreateOrder == true,
               "Native quote review uses injected time instead of the wall clock")
        timed.clock.instant = origin.addingTimeInterval(300)
        await reject({ _ = try await timed.controller.select(reviewed.card!, .init(action: .review), conversationID: chooseID) },
                     "Review accepted an exactly expired historical quote")
        timed.clock.instant = origin
        let expiredChoiceID = UUID(), expiredChoice = try await timed.quoteCard(expiredChoiceID)
        timed.clock.instant = origin.addingTimeInterval(300)
        await reject({ _ = try await timed.controller.select(expiredChoice, .init(action: .choose, value: expiredChoice.options[0].id), conversationID: expiredChoiceID) },
                     "Choice accepted an exactly expired historical quote")
        expect(timed.backend.fixture.submissions.isEmpty, "Expiry checks cannot dispatch an order")

        timed.clock.instant = origin.addingTimeInterval(400)
        let (unknownRequest, unknownQuote) = try await timed.scopedQuote(goods: "Timestamp fixture water")
        try PaotuiFixtureRuntime.confirmNativeQuote(unknownQuote, in: timed.store, request: unknownRequest)
        timed.backend.fixture.failSubmit = true
        timed.clock.instant = origin.addingTimeInterval(412)
        let unknown = await timed.store.submitConfirmed(unknownQuote, for: unknownRequest)
        guard case .outcomeUnknown(let attemptID, _, _) = unknown else { preconditionFailure("Fixture submission did not retain an unknown result") }
        expect(timed.store.pendingReviews.first?.id == attemptID && timed.store.pendingReviews.first?.createdAt == timed.clock.instant,
               "The real facade's journal records attempt time from the connection")
        let unknownRow = try timed.receipts().last!
        expect(savedDate(unknownRow["createdAt"]) == timed.clock.instant && unknownRow["state"] as? String == "unknown",
               "The injected attempt timestamp is durable")
        timed.clock.instant = origin.addingTimeInterval(489)
        try timed.store.recordReview(attemptID: attemptID, conclusion: .stillUnknown)
        expect(timed.store.pendingReviews.first?.reviewedAt == timed.clock.instant && timed.store.hasUnresolvedSubmission,
               "Human review uses the same clock while retaining an uncertain barrier")
        let reviewRows = try timed.receipts().last!["reviews"] as! [[String: Any]]
        expect(savedDate(reviewRows.last!["reviewedAt"]) == timed.clock.instant && reviewRows.last!["source"] as? String == "user_report_in_sela",
               "Human review timestamp and source are durable through the real facade")
        timed.clock.instant = origin.addingTimeInterval(500)
        try timed.store.recordReview(attemptID: attemptID, conclusion: .believesNotCreated)
        expect(!timed.store.hasUnresolvedSubmission && timed.backend.fixture.submissions.count == 1,
               "A recorded human conclusion never replays the transport")

        // Reinstalling the identical token changes authority even though the
        // fingerprint and original account's durable order facts stay the same.
        for direct in [false, true] {
            let pending = try DependencyScenario(root: root)
            let globalBefore = try await pending.globalQuote()
            let (scopedRequest, scopedBefore) = try await pending.scopedQuote()
            try PaotuiFixtureRuntime.confirmNativeQuote(scopedBefore, in: pending.store, request: scopedRequest)
            let oldEpoch = pending.connection.epoch, oldAccount = pending.store.chatAccount
            let gate = pending.backend.pause("submit_order")
            let submission = Task { await pending.store.submitConfirmed(scopedBefore, for: scopedRequest) }
            await gate.waitUntilEntered()
            expect(pending.store.busy && pending.store.hasUnresolvedSubmission, "A durable attempt and facade lock precede dispatch")
            if direct { try pending.connection.installCredential(pending.credential) }
            else { try pending.store.installCredential(pending.credential) }
            expect(pending.connection.epoch != oldEpoch && pending.store.chatAccount == oldAccount,
                   "Same-token reinstall revokes the epoch without inventing a new account")
            expect(!pending.store.ready && pending.store.quotes.isEmpty && !pending.store.isCurrent(scopedRequest),
                   "Same-token reinstall revokes cached global and scoped preparation")
            expect(!pending.store.isCurrentWorkbenchQuote(globalBefore) && !pending.store.canSubmit(scopedBefore, for: scopedRequest),
                   "No old quote remains submit-capable after same-token reinstall")
            let messageAtRevocation = pending.store.message, statusAtRevocation = pending.store.orderStatus
            gate.resume()
            let result = await submission.value
            expectCreated(result, "A dispatched late success retains its typed created result")
            expect(pending.store.paymentURL == nil && pending.store.orderStatus == statusAtRevocation && pending.store.message == messageAtRevocation,
                   "A stale late submission cannot publish payment, status or success message")
            let row = try pending.receipts().last!
            expect(row["state"] as? String == "created" && row["orderID"] as? String == "fixture-order-created" && row["account"] as? String == oldAccount,
                   "Late created facts remain durably attached to the original account")
            expect(!pending.store.hasUnresolvedSubmission && pending.store.lastOrderID == "fixture-order-created" && pending.backend.fixture.submissions.count == 1,
                   "Late success settles its single original attempt without retrying")
            let restored = MeituanPaotuiStore(connection: PaotuiFixtureRuntime.connection(clock: pending.clock.value),
                receiptURL: pending.receiptURL, clientFactory: pending.backend.client)
            expect(restored.lastOrderID == "fixture-order-created" && !restored.hasUnresolvedSubmission,
                   "A fresh facade restores the created fact after a same-token authority change")
        }

        let staleConversation = try DependencyScenario(root: root), staleID = UUID()
        let staleCard = try await staleConversation.confirmation(staleID)
        let conversationGate = staleConversation.backend.pause("submit_order")
        let conversationSubmission = Task { try await staleConversation.controller.select(staleCard, .init(action: .confirm), conversationID: staleID) }
        await conversationGate.waitUntilEntered()
        try staleConversation.connection.installCredential(staleConversation.credential)
        conversationGate.resume()
        await reject({ _ = try await conversationSubmission.value }, "A same-token connection replacement published a stale native receipt card")
        expect(!staleConversation.controller.isCurrent(staleCard) && staleConversation.store.paymentURL == nil && staleConversation.store.orderStatus.isEmpty && staleConversation.store.message.isEmpty,
               "The controller and facade cannot adopt a same-token late submission presentation")
        expect(try staleConversation.receipts().last!["state"] as? String == "created", "Rejecting the stale native reply preserves the actual created receipt")

        for conversation in [false, true] {
            let pendingRead = try DependencyScenario(root: root)
            try await pendingRead.store.loadAddresses()
            pendingRead.store.draft = PaotuiDraft(service: .buy, recipientID: "address:1", nearby: true, goods: "Gated read fixture")
            let readID = UUID()
            let requestCard = conversation ? try await pendingRead.request(readID).card : nil
            let gate = pendingRead.backend.pause("delivery_preview")
            let read = Task {
                if let requestCard { _ = try await pendingRead.controller.select(requestCard, .init(action: .quote), conversationID: readID) }
                else { _ = try await pendingRead.store.preview() }
            }
            await gate.waitUntilEntered()
            try pendingRead.connection.installCredential(pendingRead.credential)
            let messageAtRevocation = pendingRead.store.message
            gate.resume()
            await reject({ try await read.value }, "A pre-reinstall read restored a stale quote")
            expect(!pendingRead.store.ready && pendingRead.store.addresses.isEmpty && pendingRead.store.quotes.isEmpty && pendingRead.store.paymentURL == nil,
                   "Direct same-token reinstall keeps late reads from restoring cached readiness or quotes")
            expect(pendingRead.store.message == messageAtRevocation && pendingRead.backend.fixture.submissions.isEmpty,
                   "Rejected late reads publish no stale success and create no order")
            if let requestCard { expect(!pendingRead.controller.isCurrent(requestCard), "Direct connection changes revoke a conversation's old read card") }
        }

        // A failed credential save must leave usable state intact. Successful
        // direct connection mutations must invalidate that same facade state.
        let storage = DependencyCredentialStorage(), cached = try DependencyScenario(root: root, storage: storage)
        let (initialRequest, initial) = try await cached.scopedQuote()
        try PaotuiFixtureRuntime.confirmNativeQuote(initial, in: cached.store, request: initialRequest)
        expectCreated(await cached.store.submitConfirmed(initial, for: initialRequest), "The cache fixture creates a real typed success through the facade")
        let nativeRow = try cached.receipts().last!
        let nativeContext = nativeRow["context"] as! [String: Any]
        expect(UUID(uuidString: nativeContext["sessionID"] as! String) == initialRequest.sessionID &&
               UUID(uuidString: nativeContext["conversationID"] as! String) == initialRequest.origin.conversationID,
               "Native Store persists the exact original Session and conversation, rather than the selected screen")
        expect(UUID(uuidString: nativeContext["quoteID"] as! String) == initial.id &&
               UUID(uuidString: nativeContext["credentialEpoch"] as! String) == initialRequest.authorizationEpoch &&
               (nativeContext["revision"] as! NSNumber).uint64Value == initialRequest.revision,
               "Native receipt correlation captures original quote, revision and credential generation")
        let localBinding = nativeRow["credentialBinding"] as! [String: Any]
        expect(localBinding["kind"] as? String == "credentialScope" && localBinding["fingerprint"] as? String == cached.store.chatAccount &&
               nativeContext["providerAccountID"] == nil,
               "The durable binding remains a local credential scope and never invents stable provider identity")
        let createdEvent = cached.store.diagnosticsSnapshot.events.last { $0.command == .submitOrder && $0.result == .created }
        expect(createdEvent?.context.attemptID == UUID(uuidString: nativeRow["attemptID"] as! String) &&
               createdEvent?.context.sessionID == initialRequest.sessionID && createdEvent?.context.conversationID == initialRequest.origin.conversationID &&
               createdEvent?.context.quoteID == initial.id && createdEvent?.context.credentialEpoch == initialRequest.authorizationEpoch &&
               createdEvent?.context.revision == initialRequest.revision && createdEvent?.durationMilliseconds != nil,
               "Safe created diagnostics correlate to the same durable attempt and original native grant")
        let safeDiagnostics = cached.store.diagnosticsSnapshot.jsonString
        expect(!safeDiagnostics.contains(cached.credential) && !safeDiagnostics.contains(cached.store.chatAccount) &&
               !safeDiagnostics.contains("13800000000") && !safeDiagnostics.contains(initial.orderToken),
               "Native diagnostic output excludes credential fingerprints, raw phones and order tokens")
        let cachedPayment = cached.store.paymentURL, cachedStatus = cached.store.orderStatus
        let cachedGlobal = try await cached.globalQuote()
        let (cachedScope, cachedScoped) = try await cached.scopedQuote()
        expect(cached.store.ready && cachedPayment != nil && !cachedStatus.isEmpty && cached.store.isCurrentWorkbenchQuote(cachedGlobal) && cached.store.canSubmit(cachedScoped, for: cachedScope),
               "The cache fixture contains readiness, payment and both valid quote authorities")
        let validEpoch = cached.connection.epoch
        storage.failSave = true
        await reject({ try cached.connection.installCredential(cached.credential) }, "The fixture's failed vault save unexpectedly succeeded")
        expect(cached.connection.epoch == validEpoch && cached.connection.credential == cached.credential,
               "Failed secure persistence does not revoke the current credential authority")
        expect(cached.store.ready && cached.store.paymentURL == cachedPayment && cached.store.orderStatus == cachedStatus && cached.store.isCurrentWorkbenchQuote(cachedGlobal) && cached.store.canSubmit(cachedScoped, for: cachedScope),
               "Failed same-token persistence preserves the facade's valid preparation and payment")
        await reject({ try cached.connection.disconnect() }, "A failed disconnect unexpectedly saved")
        expect(cached.connection.epoch == validEpoch && cached.store.isCurrent(cachedScope) && cached.store.isCurrentWorkbenchQuote(cachedGlobal),
               "A failed disconnect preserves the same usable authority and cached quotes")
        storage.failSave = false
        try cached.connection.installCredential(cached.credential)
        expect(!cached.store.ready && cached.store.paymentURL == nil && cached.store.quotes.isEmpty && !cached.store.isCurrent(cachedScope),
               "Direct successful same-token install immediately invalidates cached facade state")
        expect(!cached.store.isCurrentWorkbenchQuote(cachedGlobal) && !cached.store.canSubmit(cachedScoped, for: cachedScope),
               "Direct successful same-token install revokes both old quote authorities")
        let cancelGlobal = try await cached.globalQuote(), (cancelScope, cancelScoped) = try await cached.scopedQuote()
        cached.connection.cancelAuthorization()
        expect(!cached.store.ready && cached.store.paymentURL == nil && cached.store.quotes.isEmpty && !cached.store.isCurrent(cancelScope),
               "Direct authorization cancellation propagates epoch invalidation into the facade")
        expect(!cached.store.isCurrentWorkbenchQuote(cancelGlobal) && !cached.store.canSubmit(cancelScoped, for: cancelScope),
               "Authorization cancellation cannot retain old global or scoped quotes")
        let disconnectGlobal = try await cached.globalQuote(), (disconnectScope, disconnectScoped) = try await cached.scopedQuote()
        try cached.connection.disconnect()
        expect(!cached.store.configured && !cached.store.ready && cached.store.paymentURL == nil && cached.store.quotes.isEmpty && cached.store.draft == PaotuiDraft(),
               "Direct disconnect clears connection readiness, payment and preparation")
        expect(!cached.store.isCurrentWorkbenchQuote(disconnectGlobal) && !cached.store.canSubmit(disconnectScoped, for: disconnectScope),
               "Direct disconnect cannot retain any old quote authority")

        // The actual core consumes an explicit interpreter and URL opener. No
        // substitute platform/model types or native side effects are involved.
        let boundaries = try DependencyScenario(root: root)
        var openedURLs: [URL] = [], interpretedQuestions: [String] = [], interpretedTimes: [Date] = []
        var interpretedMemories: [String] = [], extractionPrompts: [String] = []
        let boundaryController = MeituanPaotuiConversation(store: boundaries.store, openURL: { openedURLs.append($0); return true })
        let input = try ConversationRoutingInput(question: "打开普通外卖菜单", history: [], taskContext: "{}",
            memoryContext: "explicit fixture reference", now: boundaries.clock.instant, timeZoneIdentifier: "Asia/Shanghai")
        let boundaryID = UUID()
        let ordinaryFood = try await boundaryController.respond(question: input.question, history: [], conversationID: boundaryID,
            routingInput: input, interpret: { supplied, prompt in
                interpretedQuestions.append(supplied.question); interpretedTimes.append(supplied.referenceTime)
                interpretedMemories.append(supplied.memoryContext); extractionPrompts.append(prompt)
                return #"{"intent":"ordinary_food"}"#
            })
        expect(interpretedQuestions == [input.question] && interpretedTimes == [boundaries.clock.instant] && interpretedMemories == [input.memoryContext],
               "The actual core passes the host's explicit routing envelope to its interpreter")
        expect(extractionPrompts.count == 1 && extractionPrompts[0].contains("ordinary_food") && ordinaryFood.card?.kind == "mode",
               "The injected interpreter receives the production extraction contract and drives ordinary-food routing")
        expect(openedURLs.isEmpty && boundaries.backend.requests.isEmpty, "Interpretation alone neither opens a URL nor contacts the provider")
        let opened = try await boundaryController.select(ordinaryFood.card!, .init(action: .choose, value: "open_meituan"), conversationID: boundaryID)
        expect(openedURLs.map(\.absoluteString) == ["https://i.meituan.com/"] && opened.card == nil,
               "Only the explicit ordinary-food choice invokes the injected URL opener")
        expect(boundaries.backend.requests.isEmpty && boundaries.backend.fixture.submissions.isEmpty,
               "The ordinary-food boundary cannot create a running provider request or order")
        do {
            _ = try await boundaryController.respond(question: "缺少解释器", history: [], conversationID: UUID())
            preconditionFailure("Missing interpreter unexpectedly constructed a native model client")
        } catch {
            expect(error.localizedDescription.contains("解释服务尚未连接"), "Missing interpretation fails with an explicit safe dependency error")
        }
        expect(boundaries.backend.requests.isEmpty && openedURLs.count == 1,
               "A missing interpreter has no provider or URL-opening side effects")
        let recovered = try await boundaryController.respond(question: "补上解释器", history: [], conversationID: UUID(), interpret: { supplied, _ in
            expect(supplied.question == "补上解释器", "The core creates a routing envelope when the host supplies only an interpreter")
            expect(supplied.referenceTime == boundaries.clock.instant, "The fallback interpretation envelope uses the same injected connection clock")
            return #"{"service":"buy","goods":"Boundary fixture water","nearby":true,"recipient":"Fixture address 1"}"#
        })
        expect(recovered.card?.kind == "request" && recovered.card?.goods == "Boundary fixture water" && boundaries.backend.fixture.submissions.isEmpty,
               "An explicit interpreter can resume production preparation without implicit model construction")

        print("PASS: \(checks) actual-core dependency integration checks: one clock through HTTP/pricing/cards/journal, same-token late-result authority, direct connection cache invalidation, failed-vault preservation and explicit interpretation/URL boundaries; offline fixtures only")
    }
}
