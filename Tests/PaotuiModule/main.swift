import Foundation
import Combine

@MainActor private final class ModuleGate {
    var entered = false
    private var blocked: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        entered = true; observers.forEach { $0.resume() }; observers = []
        await withCheckedContinuation { blocked = $0 }
    }
    func wait() async { if !entered { await withCheckedContinuation { observers.append($0) } } }
    func release() { blocked?.resume(); blocked = nil }
}

/// A deliberately adversarial offline provider retains phones in text fields.
/// Production client parsing and Session ownership still run unchanged.
@MainActor private final class PrivacyProvider {
    let base = Backend()
    func client(_ key: String) -> MeituanPaotuiClient {
        MeituanPaotuiClient(credential: key, transport: { request in
            let response = try self.base.respond(request)
            var outer = try JSONSerialization.jsonObject(with: response.0) as! [String: Any]
            var inner = try JSONSerialization.jsonObject(with: Data((outer["data"] as! String).utf8)) as! [String: Any]
            var data = inner["data"] as! [String: Any]
            switch request.url!.lastPathComponent {
            case "get_address_list":
                data["userAddresses"] = (data["userAddresses"] as! [[String: Any]]).map { row in
                    var row = row; row["name"] = "联系人13800000000"; row["address"] = "Fixture address 13800000000"
                    row["houseNumber"] = "101（13800000000）"; row["phone"] = "13800000000"; return row
                }
            case "search_poi":
                var result = data["result"] as! [String: Any]
                result["pois"] = (result["pois"] as! [[String: Any]]).map { row in
                    var row = row; row["name"] = "门店13800000000"; row["address"] = "商户地址13800000000"; return row
                }
                data["result"] = result
            case "delivery_preview":
                data["distanceDesc"] = "距离说明13800000000"; data["estimateDeliveryTimeText"] = "预计说明13800000000"
                data["commonConfig"] = ["goodsPayDesc": "商品费联系13800000000"]
            default: break
            }
            inner["data"] = data
            outer["data"] = String(decoding: try JSONSerialization.data(withJSONObject: inner), as: UTF8.self)
            return (try JSONSerialization.data(withJSONObject: outer), response.1)
        })
    }
}

@MainActor private final class ModuleScenario {
    let backend = Backend()
    let store: MeituanPaotuiStore
    let controller: MeituanPaotuiConversation
    let module: PaotuiModule
    let receiptURL: URL
    var raw = "{}"
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var gate: ModuleGate?
    init(root: URL, clientFactory: ((String) -> MeituanPaotuiClient)? = nil) throws {
        receiptURL = root.appendingPathComponent(UUID().uuidString + ".json")
        // A mutable fixture clock belongs to the dependency, never the system.
        var clockValue: ModuleScenario?
        store = MeituanPaotuiStore(connection: PaotuiFixtureRuntime.connection(clock: PaotuiClock(now: {
            clockValue?.now ?? Date(timeIntervalSince1970: 1_800_000_000)
        })), receiptURL: receiptURL, clientFactory: clientFactory ?? backend.client)
        try store.installCredential("offline-module-fixture-key")
        controller = MeituanPaotuiConversation(store: store)
        module = PaotuiModule(store: store, conversation: controller)
        clockValue = self
    }
    func text(_ id: UUID, plan: [String: Any], question: String = "帮我用跑腿买一瓶水，送到 Fixture address 1", history: [AssistantMessage] = []) async throws -> PaotuiChatReply {
        raw = String(decoding: try JSONSerialization.data(withJSONObject: plan), as: UTF8.self)
        let input = try ConversationRoutingInput(question: question, history: history, taskContext: "{}", now: now, conversationID: id)
        return try await module.handle(.text(question: question, history: history),
            context: .init(conversationID: id, requestID: UUID()), routingInput: input, interpret: { _, _ in
                let raw = self.raw, gate = self.gate; self.gate = nil
                if let gate { await gate.hold() }
                return raw
            })
    }
    func request(_ id: UUID, inquiryOnly: Bool = false) async throws -> PaotuiChatReply {
        try await text(id, plan: ["service": "buy", "goods": "水一瓶", "recipient": "address:1", "nearby": true, "inquiryOnly": inquiryOnly])
    }
    func select(_ card: PaotuiChatCard, id: UUID, action: PaotuiChatSelection.Action, value: String = "") async throws -> PaotuiChatReply {
        try await module.handle(.card(card, .init(action: action, value: value)), context: .init(conversationID: id, requestID: UUID()))
    }
    func confirmation(_ id: UUID) async throws -> PaotuiChatCard {
        let request = try await self.request(id)
        let quotes = try await select(request.card!, id: id, action: .quote)
        return try await select(quotes.card!, id: id, action: .choose, value: quotes.card!.options[0].id).card!
    }
}

@main struct ModuleChecks {
    private static var checks = 0
    private static func expect(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }
    @MainActor private static func reject(_ action: () async throws -> Void, _ label: String) async {
        do { try await action(); preconditionFailure(label) } catch { checks += 1 }
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paotui-module-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = PrivacyProvider(), privateID = UUID()
        let privacy = try ModuleScenario(root: root, clientFactory: provider.client)
        let addressSelection = try await privacy.text(privateID, plan: ["service": "buy", "goods": "水一瓶13800000000", "remark": "备注13800000000", "nearby": true])
        expect(privacy.store.addresses[0].contact.contains("13800000000") && privacy.store.addresses[0].fullAddress.contains("13800000000"), "Execution addresses keep the actual provider values")
        expect(!String(decoding: try JSONEncoder().encode(addressSelection.card!), as: UTF8.self).contains("13800000000"), "Address selection card redacts adversarial provider option title and contact")
        expect(addressSelection.card!.options[0].title.contains("138****0000") && addressSelection.card!.options[0].detail.contains("138****0000"), "Native address options retain useful masked contact evidence")
        let privateRequest = try await privacy.select(addressSelection.card!, id: privateID, action: .choose, value: "address:1")
        let privateSummary = privacy.module.summary(for: privateID)!
        expect(!String(reflecting: privateSummary).contains("13800000000") && privateSummary.recipient!.contact.contains("138****0000"), "Summary redacts provider contact names, addresses and user draft display strings")
        expect(privacy.store.existingSession(for: privateID)!.draft.goods.contains("13800000000") && privacy.store.existingSession(for: privateID)!.draft.remark.contains("13800000000"), "Safe display redaction leaves the execution requirement unchanged")
        expect(!String(decoding: try JSONEncoder().encode(privateRequest.card!), as: UTF8.self).contains("13800000000"), "Request card receives only the redacted draft and selected place")
        let privateQuotes = try await privacy.select(privateRequest.card!, id: privateID, action: .quote)
        let privateQuoteSummary = privacy.module.summary(for: privateID)!
        expect(!String(reflecting: privateQuoteSummary).contains("13800000000"), "Quote summary redacts recipient/title/estimate/distance/provider note and contact strings")
        expect(!String(decoding: try JSONEncoder().encode(privateQuotes.card!), as: UTF8.self).contains("13800000000"), "Projected quote card and choice details never retain the full provider phone")
        expect(privacy.store.existingSession(for: privateID)!.quotes[0].recipientTitle.contains("13800000000") && privacy.store.existingSession(for: privateID)!.quotes[0].request["recipient"] != nil, "Canonical quote retains its actual request while safe projection stays masked")
        let privatePlaces = try await privacy.text(privateID, plan: ["store": "Fixture Kitchen", "nearby": false])
        expect(privacy.store.existingSession(for: privateID)!.places[0].title.contains("13800000000"), "Verified merchant execution records preserve the provider source")
        let privatePlacesJSON = String(decoding: try JSONEncoder().encode(privatePlaces.card!), as: UTF8.self)
        expect(!String(reflecting: privacy.module.summary(for: privateID)!).contains("13800000000") && !privatePlacesJSON.contains("13800000000"), "Merchant summary and selection card redact raw provider names and addresses")
        let purePrivate = PaotuiCardProjector.project(privateSummary, output: .init(text: "联系13800000000", kind: "info", options: [.init(id: "reference", title: "名字13800000000", detail: "地址13800000000")], extraNote: "说明13800000000", noteOverride: "备注13800000000"))
        expect(!String(decoding: try JSONEncoder().encode(purePrivate), as: UTF8.self).contains("13800000000"), "Pure projection redacts all output display text while preserving reference IDs")
        let scenario = try ModuleScenario(root: root), id = UUID(), otherID = UUID()
        expect(scenario.module.summary(for: id) == nil && scenario.store.existingSession(for: id) == nil, "Route inspection must not create a preparation")
        let historical = PaotuiChatCard(conversationID: id, kind: "confirm", title: "保存的确认")
        expect(!scenario.module.presentation(for: historical, conversationID: id).isCurrent, "Saved history alone has no action authority")
        let wrongRouting = try ConversationRoutingInput(question: "本轮问题", history: [], taskContext: "{}", conversationID: otherID)
        await reject({ _ = try await scenario.module.handle(.text(question: "本轮问题", history: []), context: .init(conversationID: id, requestID: UUID()), routingInput: wrongRouting, interpret: { _, _ in "{}" }) }, "An approved input from another chat crossed the module boundary")
        let mismatchedQuestion = try ConversationRoutingInput(question: "另一轮问题", history: [], taskContext: "{}", conversationID: id)
        await reject({ _ = try await scenario.module.handle(.text(question: "本轮问题", history: []), context: .init(conversationID: id, requestID: UUID()), routingInput: mismatchedQuestion, interpret: { _, _ in "{}" }) }, "Routing approval for another question crossed the module boundary")
        expect(scenario.store.existingSession(for: id) == nil, "Rejected approved-input mismatch never creates a Session")
        var updates = 0
        let observer = scenario.module.objectWillChange.sink { _ in updates += 1 }
        let request = try await scenario.request(id), card = request.card!
        expect(updates > 0, "The module forwards actual Store and Session changes")
        let session = scenario.store.existingSession(for: id)!, revision = session.revision
        let summary = scenario.module.summary(for: id)!
        expect(summary.isActivePreparation && summary.draft.service == "buy" && summary.draft.goods == "水一瓶", "Summary reflects the live requirement")
        expect(scenario.store.existingSession(for: id) === session && session.revision == revision, "Summary is a non-mutating read")
        expect(summary.recipient?.contact.contains("****") == true, "Summary contact stays masked")
        expect(!String(reflecting: summary).contains("13800000000") && !String(reflecting: summary).contains("offline-module-fixture-key"), "Summary never exports raw phones or credentials")
        expect(Set(summary.routingPayload.keys) == ["active", "phase", "service", "goods", "inquiryOnly", "missingFields", "quotes"], "Routing payload is a narrow safe whitelist")
        var projected = PaotuiCardProjector.project(summary, output: .init(text: request.text, kind: "request"))
        expect(projected.id != card.id && !scenario.module.presentation(for: projected, conversationID: id).isCurrent, "Pure projection cannot offer itself or restore a card identity")
        projected.id = card.id
        expect(projected == card, "Pure projector assembles every request display field before registration")
        projected.goods = "伪造商品"
        expect(!scenario.module.presentation(for: projected, conversationID: id).isCurrent, "Same-ID display mutation loses authority")
        expect(!scenario.module.presentation(for: card, conversationID: otherID).isCurrent, "Presentation is bound to the original chat")
        expect(scenario.module.presentation(for: card, conversationID: id).allows(.quote), "Current request offers read-only quote action")
        await reject({ _ = try await scenario.select(card, id: otherID, action: .quote) }, "A card crossed chat identity")
        expect(session.isCurrent(card), "Rejected cross-chat action does not consume the true card")

        let quotes = try await scenario.select(card, id: id, action: .quote)
        let quoteCard = quotes.card!, quoteSummary = scenario.module.summary(for: id)!
        expect(quoteSummary.quotes.count == 1 && !String(reflecting: quoteSummary).contains("fixture-token"), "Quote summary exports display facts without provider order token")
        var quoteProjection = PaotuiCardProjector.project(quoteSummary, output: .init(text: quotes.text, kind: "quotes", options: quoteCard.options, quote: quoteSummary.quotes[0]))
        quoteProjection.id = quoteCard.id
        expect(quoteProjection == quoteCard, "Pure projector matches complete quote card display")
        let toolID = UUID()
        let toolAddresses = try await scenario.module.query(#"{"action":"addresses"}"#, context: .init(taskID: toolID, invocationID: UUID()))
        let addressEnvelope = try JSONSerialization.jsonObject(with: Data(toolAddresses.utf8)) as! [String: Any]
        expect(addressEnvelope["kind"] as? String == "addresses", "System queries enter the same module with explicit task invocation context")
        let toolPrice = try await scenario.module.query(#"{"action":"preview_buy","recipient":"address:1","nearby":true,"goods":"本任务水一瓶"}"#, context: .init(taskID: toolID, invocationID: UUID()))
        let priceEnvelope = try JSONSerialization.jsonObject(with: Data(toolPrice.utf8)) as! [String: Any]
        expect(priceEnvelope["kind"] as? String == "quotes" && priceEnvelope["source"] as? String == "meituan_paotui", "The shared module returns bounded source JSON through its query-only adapter")
        expect(scenario.module.presentation(for: quoteCard, conversationID: id).isCurrent && session.quotes[0].id == quoteSummary.quotes[0].id, "Tool invocation cannot replace native card or quote authority")
        await reject({ _ = try await scenario.module.query(#"{"action":"preview_buy","recipient":"address:1","nearby":true,"goods":"借用地址"}"#, context: .init(taskID: UUID(), invocationID: UUID())) }, "The shared module query adapter borrowed another task's reference")
        await reject({ _ = try await scenario.module.query(#"{"action":"submit"}"#, context: .init(taskID: toolID, invocationID: UUID())) }, "The shared module query adapter exposed an order command")
        // Exact presentation uses the same production quote value without
        // allowing its token, request or credential to cross the display DTO.
        let template = session.quotes[0]
        for (minorUnits, expectedText) in [(Int64(1234), "12.34 元"), (Int64.max, "92233720368547758.07 元")] {
            let exactAmount = try PaotuiMoney(minorUnits: minorUnits)
            let exactQuote = PaotuiQuote(id: UUID(), draft: PaotuiDraft(service: .send, goods: "文件一份"),
                senderTitle: template.senderTitle, recipientTitle: template.recipientTitle,
                serviceTitle: "帮取送", distance: template.distance, estimate: template.estimate,
                deliveryAmount: exactAmount, originalDeliveryAmount: exactAmount,
                goodsPaymentNote: "无商品费", quotedAt: scenario.now, agreementURL: nil, agreementTitle: "",
                account: "offline-display-account", request: ["private": "offline-private-value"],
                orderToken: "offline-display-token", couponViewID: "")
            let safeQuote = PaotuiSessionSummary.Quote(exactQuote, canCreateOrder: true)
            var exactSummary = quoteSummary
            exactSummary.draft = .init(service: "send", goods: "文件一份")
            exactSummary.quotes = [safeQuote]
            let exactCard = PaotuiCardProjector.project(exactSummary, output: .init(text: "精确费用", kind: "quotes", quote: safeQuote))
            expect(safeQuote.currency == "CNY" && safeQuote.deliveryFeeMinorUnits == minorUnits && safeQuote.feeText == expectedText, "Safe summary retains every integer fen and exact CNY text")
            expect(exactCard.valid && exactCard.deliveryFeeDisplayText == expectedText && exactCard.deliveryFeeText == expectedText, "Projected delivery display never rounds through Double")
            expect(exactCard.goodsPriceDisplayText == "0 元" && exactCard.totalDisplayText == expectedText, "Send total adds exact zero goods fee without losing a fen")
            let routingQuotes = exactSummary.routingPayload["quotes"] as! [[String: Any]]
            expect(routingQuotes[0]["deliveryFeeMinorUnits"] as? Int64 == minorUnits && routingQuotes[0]["deliveryFeeText"] as? String == expectedText, "Routing payload preserves exact fee fields")
            expect(!String(reflecting: exactSummary).contains("offline-display-token") && !String(reflecting: exactSummary).contains("offline-private-value"), "Exact money exports no provider token or raw request")
            let encoded = try JSONEncoder().encode(exactCard)
            let roundTrip = try JSONDecoder().decode(PaotuiChatCard.self, from: encoded)
            expect(roundTrip.deliveryFeeMinorUnits == minorUnits && roundTrip.totalDisplayText == expectedText, "Saved exact display survives Codable roundtrip")
            if minorUnits == Int64.max {
                var overflow = exactCard; overflow.goodsPriceMinorUnits = 1; overflow.goodsPrice = 0.01
                expect(overflow.totalDisplayText == nil, "Integer overflow stays unknown instead of falling back to rounded Double")
            }
        }
        var legacyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(quoteCard)) as! [String: Any]
        for key in ["currency", "deliveryFeeMinorUnits", "goodsPriceMinorUnits", "deliveryFeeText"] { legacyObject.removeValue(forKey: key) }
        legacyObject["deliveryFee"] = 12.34; legacyObject["goodsPrice"] = 0
        let legacyCard = try JSONDecoder().decode(PaotuiChatCard.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        expect(legacyCard.valid && legacyCard.currency == nil && legacyCard.deliveryFeeMinorUnits == nil, "Old saved cards decode with absent exact-money fields")
        expect(legacyCard.deliveryFeeDisplayText == "12.34 元" && legacyCard.goodsPriceDisplayText == "0 元" && legacyCard.totalDisplayText == "12.34 元", "Legacy money display remains readable")
        var partialExact = legacyCard; partialExact.currency = "CNY"; partialExact.deliveryFeeMinorUnits = 1234
        expect(partialExact.totalDisplayText == nil && partialExact.goodsPriceDisplayText == nil, "Partial exact evidence keeps unknown goods and total unknown")
        let confirmation = try await scenario.select(quoteCard, id: id, action: .choose, value: quoteCard.options[0].id).card!
        expect(scenario.module.presentation(for: confirmation, conversationID: id).canCreateOrder, "Only current native confirmation can offer submit")
        let reopened = PaotuiModule(store: scenario.store, conversation: scenario.controller)
        expect(reopened.summary(for: id) != nil && reopened.presentation(for: confirmation, conversationID: id).canCreateOrder, "Same-process host reopen reads the existing live session")
        scenario.now = confirmation.validUntil!
        let expired = scenario.module.presentation(for: confirmation, conversationID: id)
        expect(expired.isCurrent && !expired.canCreateOrder && expired.allows(.quote), "Expiry preserves refresh and removes submission immediately")
        await reject({ _ = try await scenario.select(confirmation, id: id, action: .confirm) }, "Expired confirmation submitted")
        expect(scenario.backend.submissions.isEmpty, "Expiry test creates no order")

        let restartedStore = MeituanPaotuiStore(connection: PaotuiFixtureRuntime.connection(), receiptURL: scenario.receiptURL, clientFactory: scenario.backend.client)
        let restartedModule = PaotuiModule(store: restartedStore, conversation: MeituanPaotuiConversation(store: restartedStore))
        expect(restartedModule.summary(for: id) == nil && !restartedModule.presentation(for: confirmation, conversationID: id).isCurrent, "Restart cannot reconstruct authority from saved cards")
        scenario.module.lifecycle(.cleared(id))
        expect(!session.isActive && scenario.module.summary(for: id) == nil && scenario.store.existingSession(for: id) == nil, "Clear synchronously closes and removes exactly the original Session")
        expect(!scenario.module.presentation(for: confirmation, conversationID: id).isCurrent, "Clear revokes historical card actions immediately")
        let renewed = try await scenario.request(id)
        expect(scenario.store.existingSession(for: id)?.sessionID != session.sessionID, "Continuing after clear creates a fresh Session")
        expect(!scenario.module.presentation(for: confirmation, conversationID: id).isCurrent && scenario.module.presentation(for: renewed.card!, conversationID: id).isCurrent, "An old card never resumes authority in the rebuilt chat")
        let other = try await scenario.request(otherID)
        scenario.module.lifecycle(.cleared(id))
        expect(scenario.module.presentation(for: other.card!, conversationID: otherID).isCurrent, "Clearing one chat keeps another chat intact")
        let authUpdates = updates
        try scenario.store.installCredential("offline-replacement-key")
        expect(updates > authUpdates && scenario.module.summary(for: otherID) == nil && !scenario.module.presentation(for: other.card!, conversationID: otherID).isCurrent, "Credential change publishes and closes all old preparation authority")

        let inquiry = try ModuleScenario(root: root), inquiryID = UUID()
        let inquiryRequest = try await inquiry.request(inquiryID, inquiryOnly: true)
        let inquiryQuotes = try await inquiry.select(inquiryRequest.card!, id: inquiryID, action: .quote)
        let inquiryConfirm = try await inquiry.select(inquiryQuotes.card!, id: inquiryID, action: .choose, value: inquiryQuotes.card!.options[0].id).card!
        expect(inquiry.module.summary(for: inquiryID)?.inquiryOnly == true && !inquiry.module.presentation(for: inquiryConfirm, conversationID: inquiryID).canCreateOrder, "Inquiry restriction reaches both summary and live presentation")

        let racing = try ModuleScenario(root: root), raceID = UUID(), gate = ModuleGate()
        racing.gate = gate
        let pending = Task { @MainActor in try await racing.request(raceID) }
        await gate.wait()
        let beforeClear = racing.store.existingSession(for: raceID)!
        racing.module.lifecycle(.cleared(raceID)); gate.release()
        await reject({ _ = try await pending.value }, "Late interpretation revived a cleared session")
        expect(!beforeClear.isActive && racing.module.summary(for: raceID) == nil, "Late results cannot recreate cleared preparation")

        let parallel = try ModuleScenario(root: root), aID = UUID(), bID = UUID(), aGate = ModuleGate()
        parallel.gate = aGate
        let aPending = Task { @MainActor in try await parallel.request(aID) }
        await aGate.wait()
        let bReply = try await parallel.request(bID)
        aGate.release()
        let aReply = try await aPending.value
        expect(aReply.card?.conversationID == aID && bReply.card?.conversationID == bID, "Background A completion retains A's explicit destination")
        expect(parallel.module.presentation(for: bReply.card!, conversationID: bID).isCurrent && !parallel.module.presentation(for: aReply.card!, conversationID: bID).isCurrent, "A completing never replaces B's current action authority")

        let superseded = try ModuleScenario(root: root), turnID = UUID(), firstGate = ModuleGate()
        superseded.gate = firstGate
        let firstTurn = Task { @MainActor in try await superseded.request(turnID) }
        await firstGate.wait()
        let currentTurn = try await superseded.text(turnID, plan: ["service": "buy", "goods": "面包一份", "recipient": "address:1", "nearby": true])
        firstGate.release()
        await reject({ _ = try await firstTurn.value }, "An old requestID published after a newer request in the same chat")
        expect(superseded.module.presentation(for: currentTurn.card!, conversationID: turnID).isCurrent && superseded.module.summary(for: turnID)?.draft.goods == "面包一份", "Supersession leaves only the latest turn current")

        let numbered = try ModuleScenario(root: root), numberID = UUID()
        let weightChoice = try await numbered.text(numberID, plan: ["service": "send", "goods": "文件一份"])
        expect(weightChoice.card?.kind == "weight", "Incomplete send presents actual live weight choices")
        let chosen = try await numbered.text(numberID, plan: [:], question: "第一个", history: [])
        expect(chosen.card?.kind == "category" && numbered.module.summary(for: numberID)?.draft.weight == 0.5, "Ordinal text uses the Session's offered card even without a history card")

        let review = try ModuleScenario(root: root), reviewID = UUID()
        let beforeReview = try await review.confirmation(reviewID)
        var reviewUpdates = 0
        let reviewObserver = review.module.objectWillChange.sink { _ in reviewUpdates += 1 }
        // The independent journal records an offline outcome-unknown attempt.
        review.backend.failSubmit = true
        _ = try await review.select(beforeReview, id: reviewID, action: .confirm)
        expect(review.store.hasUnresolvedSubmission && !review.store.pendingReviews.isEmpty, "Unknown native submit is retained by the production journal")
        let pendingAttempt = review.store.pendingReviews[0].id
        let refreshID = UUID()
        let duringUnknown = try await review.confirmation(refreshID)
        expect(!review.module.presentation(for: duringUnknown, conversationID: refreshID).canCreateOrder, "Unknown submission blocks a newly projected confirmation")
        let beforeReviewUpdates = reviewUpdates
        try review.store.recordReview(attemptID: pendingAttempt, conclusion: .believesNotCreated)
        expect(reviewUpdates > beforeReviewUpdates && !review.module.presentation(for: duringUnknown, conversationID: refreshID).isCurrent, "Human review publishes pricing revocation immediately; old quote never regains submit")
        expect(review.module.summary(for: refreshID)?.quotes.isEmpty == true, "Review invalidation reaches safe summary")
        _ = observer; _ = reviewObserver
        print("Paotui module/projector: \(checks) checks passed")
    }
}
