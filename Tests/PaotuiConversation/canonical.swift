import Foundation

@MainActor private final class CanonicalGate {
    private var entered = false
    private var blocker: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        entered = true; observers.forEach { $0.resume() }; observers = []
        await withCheckedContinuation { blocker = $0 }
    }
    func wait() async {
        if !entered { await withCheckedContinuation { observers.append($0) } }
    }
    func release() { blocker?.resume(); blocker = nil }
}

@MainActor private final class CanonicalBackend {
    let fixture = Backend()
    var gates: [String: CanonicalGate] = [:]
    func pause(_ endpoint: String) -> CanonicalGate {
        let gate = CanonicalGate(); gates[endpoint] = gate; return gate
    }
    func client(_ key: String) -> MeituanPaotuiClient {
        MeituanPaotuiClient(credential: key, transport: { request in
            let endpoint = request.url!.lastPathComponent
            if let gate = self.gates.removeValue(forKey: endpoint) { await gate.hold() }
            let response = try self.fixture.respond(request)
            guard endpoint == "search_poi" else { return response }
            let input = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let keyword = input["keyword"] as! String
            // Every scope deliberately receives the same provider identifier.
            let data: [String: Any] = ["result": ["pois": [[
                "id": "shared-shop", "name": keyword, "address": "Fixture store " + keyword,
                "location": "113.930192,22.512682",
                "addr_info": [["level_desc": "city", "admin_code": "440300"]]
            ]]]]
            let inner = try JSONSerialization.data(withJSONObject: ["code": 0, "data": data])
            let bytes = try JSONSerialization.data(withJSONObject: ["code": 0, "result": "SUCCESS", "data": String(decoding: inner, as: UTF8.self)])
            return (bytes, response.1)
        })
    }
}

@MainActor private final class CanonicalPlanner {
    var raw = "{}"
    var gate: CanonicalGate?
    func extract() async -> String {
        let result = raw, pending = gate; gate = nil
        if let pending { await pending.hold() }
        return result
    }
}

@MainActor private final class CanonicalScenario {
    let backend = CanonicalBackend()
    let planner = CanonicalPlanner()
    let store: MeituanPaotuiStore
    let controller: MeituanPaotuiConversation
    let receiptURL: URL
    init(root: URL) throws {
        receiptURL = root.appendingPathComponent(UUID().uuidString + ".json")
        store = MeituanPaotuiStore(connection: PaotuiFixtureRuntime.connection(), receiptURL: receiptURL, clientFactory: backend.client)
        try store.installCredential("offline-canonical-session-key")
        let planner = self.planner
        controller = MeituanPaotuiConversation(store: store, planner: { _, _, _ in await planner.extract() })
    }
    func respond(_ id: UUID, _ plan: [String: Any]) async throws -> PaotuiChatReply {
        planner.raw = String(decoding: try JSONSerialization.data(withJSONObject: plan), as: UTF8.self)
        return try await controller.respond(question: "本次用户需求", history: [], conversationID: id)
    }
    func request(_ id: UUID, goods: String = "本次水一瓶", shop: String? = nil, inquiryOnly: Bool = false) async throws -> PaotuiChatReply {
        var plan: [String: Any] = ["service": "buy", "goods": goods, "recipient": "address:1", "inquiryOnly": inquiryOnly]
        if let shop { plan["store"] = shop } else { plan["nearby"] = true }
        return try await respond(id, plan)
    }
    func select(_ reply: PaotuiChatReply, action: PaotuiChatSelection.Action, value: String = "", id: UUID) async throws -> PaotuiChatReply {
        try await controller.select(reply.card!, .init(action: action, value: value), conversationID: id)
    }
    func quoted(_ request: PaotuiChatReply, id: UUID) async throws -> PaotuiChatReply {
        try await select(request, action: .quote, id: id)
    }
    func confirmation(_ request: PaotuiChatReply, id: UUID) async throws -> PaotuiChatReply {
        let quote = try await quoted(request, id: id)
        return try await select(quote, action: .choose, value: quote.card!.options[0].id, id: id)
    }
}

@main struct CanonicalSessionChecks {
    private static var checks = 0
    private static func expect(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }
    @MainActor private static func reject(_ action: () async throws -> Void, _ label: String) async {
        do { try await action(); preconditionFailure(label) } catch { checks += 1 }
    }
    private static func json(_ text: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }
    private static func patch(_ card: PaotuiChatCard, _ fields: [String: Any]) throws -> PaotuiChatCard {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(card)) as! [String: Any]
        for (key, value) in fields { object[key] = value }
        return try JSONDecoder().decode(PaotuiChatCard.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private static func notDispatched(_ result: PaotuiOrderService.SubmissionResult, _ label: String) {
        if case .notDispatched = result { checks += 1 } else { preconditionFailure(label) }
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paotui-canonical-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Card identity includes every displayed value, not just its UUID.
        let cards = try CanonicalScenario(root: root), cardID = UUID()
        let request = try await cards.request(cardID)
        let requestCard = request.card!
        let requestPatches: [[String: Any]] = [
            ["kind": "confirm"], ["options": [["id": "forged", "title": "伪造选项", "detail": ""]]],
            ["quoteID": UUID().uuidString], ["deliveryFee": 0], ["canCreateOrder": true], ["goods": "替换商品"]
        ]
        for fields in requestPatches {
            let forged = try patch(requestCard, fields)
            expect(forged.id == requestCard.id && !cards.controller.isCurrent(forged), "Changing a same-ID request card never preserves authority")
            await reject({ _ = try await cards.controller.select(forged, .init(action: .quote), conversationID: cardID) }, "Forged request card was accepted")
            expect(cards.controller.isCurrent(requestCard), "Rejecting a forged card does not consume the real request card")
        }
        await reject({ _ = try await cards.controller.select(requestCard, .init(action: .quote), conversationID: UUID()) }, "A current card crossed conversation identity")
        expect(cards.controller.isCurrent(requestCard), "Wrong-conversation selection leaves the real card current")
        let confirmation = try await cards.confirmation(request, id: cardID), exactConfirm = confirmation.card!
        for fields: [String: Any] in [["kind": "quotes"], ["quoteID": UUID().uuidString], ["deliveryFee": 0], ["canCreateOrder": false], ["inquiryOnly": true]] {
            let forged = try patch(exactConfirm, fields)
            expect(!cards.controller.isCurrent(forged), "Changing confirmation content revokes the submitted value")
            await reject({ _ = try await cards.controller.select(forged, .init(action: .confirm), conversationID: cardID) }, "Forged confirmation dispatched")
            expect(cards.controller.isCurrent(exactConfirm), "Rejected confirmation tampering leaves the exact native card usable")
        }
        expect(cards.backend.fixture.submissions.isEmpty, "No tampered card reaches dispatch")
        _ = try await cards.select(confirmation, action: .confirm, id: cardID)
        expect(cards.backend.fixture.submissions.count == 1 && cards.backend.fixture.submissions[0]["purchaseGoodDetail"] as? String == "本次水一瓶", "The unchanged native card submits its canonical quote once")

        let restarted = MeituanPaotuiStore(connection: PaotuiFixtureRuntime.connection(), receiptURL: cards.receiptURL, clientFactory: cards.backend.client)
        let restartedController = MeituanPaotuiConversation(store: restarted)
        expect(!restartedController.isCurrent(exactConfirm) && restarted.lastOrderID != nil, "A restart restores order facts without restoring card authority")

        // Text intent and inquiry-only restrictions remain business state.
        let inquiry = try CanonicalScenario(root: root), inquiryID = UUID()
        var inquiryReply = try await inquiry.confirmation(inquiry.request(inquiryID, inquiryOnly: true), id: inquiryID)
        expect(inquiryReply.card?.inquiryOnly == true && inquiryReply.card?.canCreateOrder == false, "Inquiry-only projects a non-submitting confirmation")
        await reject({ _ = try await inquiry.select(inquiryReply, action: .confirm, id: inquiryID) }, "Inquiry-only native action submitted")
        inquiryReply = try await inquiry.respond(inquiryID, ["intent": "new", "service": "buy", "goods": "新需求两瓶水", "nearby": true, "recipient": "address:1"])
        expect(inquiryReply.card?.inquiryOnly == true && inquiryReply.card?.goods == "新需求两瓶水", "Starting a new draft retains the explicit inquiry-only restriction")
        let beforeText = try await inquiry.confirmation(inquiryReply, id: inquiryID)
        let textReply = try await inquiry.respond(inquiryID, ["intent": "continue"])
        expect(textReply.card?.kind == "request" && !inquiry.controller.isCurrent(beforeText.card!), "Textual confirmation begins a new revision without submitting")
        expect(inquiry.backend.fixture.submissions.isEmpty, "Text intent never dispatches an order")

        // A high-fee acknowledgement belongs to one selected service quote.
        let high = try CanonicalScenario(root: root), highID = UUID()
        high.backend.fixture.deliveryFee = 120
        var highReply = try await high.respond(highID, ["service": "send", "goods": "文件一份", "weight": 0.5, "category": "document", "recipient": "address:1", "sender": "address:2"])
        highReply = try await high.quoted(highReply, id: highID)
        let firstID = UUID(uuidString: highReply.card!.options[0].id)!, secondID = UUID(uuidString: highReply.card!.options[1].id)!
        highReply = try await high.select(highReply, action: .choose, value: firstID.uuidString, id: highID)
        highReply = try await high.select(highReply, action: .confirm, id: highID)
        let highSession = high.store.session(for: highID)
        expect(highSession.highFeeAcknowledgedQuoteID == firstID && high.backend.fixture.submissions.isEmpty, "First expensive quote records only its own acknowledgement")
        let secondQuote = try highSession.chooseQuote(secondID, at: high.store.currentTime)
        expect(highSession.highFeeAcknowledgedQuoteID == nil && !high.controller.isCurrent(highReply.card!), "Selecting the other real service quote clears the former acknowledgement and card")
        var secondCard = PaotuiChatCard(conversationID: highID, kind: "confirm", title: "核对第二个真实服务方案")
        secondCard.quoteID = secondQuote.id; secondCard.deliveryFee = secondQuote.fee
        secondCard.canCreateOrder = high.store.canSubmit(secondQuote, for: highSession.ticket)
        secondCard = try highSession.offer(secondCard)
        let secondWarning = try await high.controller.select(secondCard, .init(action: .confirm), conversationID: highID)
        expect(secondWarning.text.contains("超过 100") && highSession.highFeeAcknowledgedQuoteID == secondID && high.backend.fixture.submissions.isEmpty, "The second expensive service requires its own new warning confirmation")
        _ = try await high.select(secondWarning, action: .confirm, id: highID)
        expect(high.backend.fixture.submissions.count == 1 && high.backend.fixture.submissions[0]["serviceType"] as? Int == 4033, "Only the explicitly twice-confirmed second service dispatches")

        // A draft ABA is still a changed revision; equality cannot revive reads.
        let aba = try CanonicalScenario(root: root)
        try await aba.store.loadAddresses()
        let original = PaotuiDraft(service: .buy, recipientID: "address:1", nearby: true, goods: "A原需求")
        var changed = original; changed.goods = "B临时需求"
        let abaID = UUID(), originalTicket = try aba.store.beginConversationRequest(abaID, draft: original)
        let quoteGate = aba.backend.pause("delivery_preview")
        let oldQuote = Task { try await aba.store.preview(for: originalTicket) }
        await quoteGate.wait()
        let changedTicket = try aba.store.updateConversationDraft(changed, for: originalTicket)
        let restoredTicket = try aba.store.updateConversationDraft(original, for: changedTicket)
        expect(restoredTicket.revision > originalTicket.revision && !aba.store.isCurrent(originalTicket) && aba.store.isCurrent(restoredTicket), "Draft ABA advances revision even after exact values are restored")
        quoteGate.release()
        await reject({ _ = try await oldQuote.value }, "An ABA-stale quote was accepted")
        expect(aba.store.session(for: abaID).quotes.isEmpty && aba.store.session(for: abaID).draft == original, "Rejected late quote cannot replace the restored draft or install pricing")
        let freshQuote = try await aba.store.preview(for: restoredTicket)[0]
        notDispatched(await aba.store.submitConfirmed(freshQuote, for: restoredTicket), "A scoped quote without a native confirmation dispatched")
        expect(aba.backend.fixture.submissions.isEmpty, "Possessing a quote and current ticket alone gives no submission authority")

        let searchID = UUID(), searchTicket = try aba.store.beginConversationRequest(searchID, draft: original)
        let searchGate = aba.backend.pause("search_poi")
        let oldSearch = Task { try await aba.store.search(keyword: "A旧门店", city: "深圳", for: searchTicket) }
        await searchGate.wait()
        let changedSearchTicket = try aba.store.updateConversationDraft(changed, for: searchTicket)
        let restoredSearchTicket = try aba.store.updateConversationDraft(original, for: changedSearchTicket)
        searchGate.release()
        await reject({ _ = try await oldSearch.value }, "An ABA-stale POI search was accepted")
        expect(aba.store.isCurrent(restoredSearchTicket) && aba.store.session(for: searchID).verifiedPlaces.isEmpty, "Late ABA search cannot install a verified reference")

        // Clear then recreate the same conversation before old work completes.
        let model = try CanonicalScenario(root: root), modelID = UUID(), modelGate = CanonicalGate()
        model.planner.gate = modelGate
        let oldModel = Task { try await model.request(modelID, goods: "旧模型需求") }
        await modelGate.wait()
        let oldSessionID = model.store.session(for: modelID).sessionID
        model.controller.clearPreparation(conversationID: modelID)
        let replacement = try await model.request(modelID, goods: "新会话需求")
        let replacementSessionID = model.store.session(for: modelID).sessionID
        modelGate.release()
        await reject({ _ = try await oldModel.value }, "A cleared model response contaminated the replacement session")
        expect(oldSessionID != replacementSessionID && model.controller.isCurrent(replacement.card!) && replacement.card?.goods == "新会话需求", "Old model lifetime cannot overwrite a recreated same-conversation Session")

        for endpoint in ["get_address_list", "search_poi", "delivery_preview"] {
            let reads = try CanonicalScenario(root: root), id = UUID()
            let oldWork: Task<PaotuiChatReply, Error>, gate: CanonicalGate
            if endpoint == "delivery_preview" {
                let oldRequest = try await reads.request(id, goods: "旧报价需求")
                gate = reads.backend.pause(endpoint)
                oldWork = Task { try await reads.quoted(oldRequest, id: id) }
            } else {
                gate = reads.backend.pause(endpoint)
                oldWork = Task { try await reads.request(id, goods: "旧读取需求", shop: endpoint == "search_poi" ? "旧门店" : nil) }
            }
            await gate.wait()
            let oldLifetime = reads.store.session(for: id).sessionID
            reads.controller.clearPreparation(conversationID: id)
            let current = try await reads.request(id, goods: "替代读取需求")
            gate.release()
            await reject({ _ = try await oldWork.value }, "Cleared late \(endpoint) restored old preparation")
            let currentSession = reads.store.session(for: id)
            expect(currentSession.sessionID != oldLifetime && reads.controller.isCurrent(current.card!), "Recreated Session keeps its current card after late \(endpoint)")
            expect(currentSession.draft.goods == "替代读取需求" && currentSession.quotes.isEmpty && reads.backend.fixture.submissions.isEmpty, "Late \(endpoint) cannot install quote authority or dispatch")
        }

        // Search/preview tools share neither POIs nor native authority.
        let scoped = try CanonicalScenario(root: root), nativeID = UUID()
        var nativeReply = try await scoped.request(nativeID, goods: "Native goods", shop: "Native shop")
        nativeReply = try await scoped.select(nativeReply, action: .choose, value: nativeReply.card!.options[0].id, id: nativeID)
        nativeReply = try await scoped.confirmation(nativeReply, id: nativeID)
        let nativeSession = scoped.store.session(for: nativeID), nativeQuote = nativeSession.quotes[0]
        try await scoped.store.search(keyword: "Workbench shop", city: "深圳")
        let sharedPlaceID = scoped.store.places[0].id
        scoped.store.draft = PaotuiDraft(service: .buy, recipientID: "address:2", senderID: sharedPlaceID, goods: "Workbench goods")
        let workbenchQuote = try await scoped.store.preview()[0]
        let initialPreviewCount = scoped.backend.fixture.previews.count
        let noSearchTask = UUID()
        let noSearchAddresses = try json(await scoped.store.tool(#"{"action":"addresses"}"#, taskID: noSearchTask))
        expect(noSearchAddresses["kind"] as? String == "addresses", "The task owns its exported saved addresses before its unowned POI is tested")
        let borrowingQuery = #"{"action":"preview_buy","recipient":"address:1","sender":"poi:shared-shop","goods":"Borrowed goods"}"#
        await reject({ _ = try await scoped.store.tool(borrowingQuery, taskID: noSearchTask) }, "A tool borrowed native/workbench verified POIs")
        expect(scoped.backend.fixture.previews.count == initialPreviewCount, "Unowned tool references are rejected before preview HTTP")
        let taskA = UUID(), taskB = UUID()
        let taskAAddresses = try json(await scoped.store.tool(#"{"action":"addresses"}"#, taskID: taskA))
        let taskBAddresses = try json(await scoped.store.tool(#"{"action":"addresses"}"#, taskID: taskB))
        expect(taskAAddresses["kind"] as? String == "addresses" && taskBAddresses["kind"] as? String == "addresses", "Independent tasks obtain their own exact saved-address exports")
        let placesJSON = try await scoped.store.tool(#"{"action":"search","keyword":"Task A shop","city":"深圳","recipient":"address:1"}"#, taskID: taskA)
        let placesObject = try json(placesJSON), placeRows = placesObject["records"] as! [[String: Any]]
        expect(placesObject["source"] as? String == "meituan_paotui" && placesObject["kind"] as? String == "places" && placeRows[0]["reference"] as? String == sharedPlaceID, "Tool search emits source-tagged parseable JSON with its real reference")
        await reject({ _ = try await scoped.store.tool(borrowingQuery, taskID: taskB) }, "A second task borrowed the first task's verified POI")
        let quoteText = try await scoped.store.tool(#"{"action":"preview_buy","recipient":"address:1","sender":"poi:shared-shop","goods":"Task A goods"}"#, taskID: taskA)
        let quoteObject = try json(quoteText), quoteRows = quoteObject["records"] as! [[String: Any]]
        expect(quoteObject["kind"] as? String == "quotes" && quoteRows[0]["goods"] as? String == "Task A goods" && quoteRows[0]["sender"] as? String == placeRows[0]["address"] as? String, "Tool preview uses only its task's actual POI snapshot")
        expect(quoteRows[0]["goodsFee"] is NSNull && quoteRows[0]["totalFee"] is NSNull && quoteRows[0]["deliveryFee"] as? Double == 18, "Source result preserves unknown purchase/total prices and actual delivery fee")
        expect(!quoteText.contains("fixture-token") && !quoteText.contains("fixture-payment") && !quoteText.contains("13800000000") && quoteRows[0]["request"] == nil && quoteRows[0]["account"] == nil, "Tool results contain no quote wire payload, tokens, credential scope or private phone")
        _ = try await scoped.store.tool(#"{"action":"search","keyword":"Task B shop","city":"深圳","recipient":"address:2"}"#, taskID: taskB)
        _ = try await scoped.store.tool(#"{"action":"preview_buy","recipient":"address:1","sender":"poi:shared-shop","goods":"Task A after B"}"#, taskID: taskA)
        let lastSender = scoped.backend.fixture.previews.last!["sender"] as! [String: Any]
        expect(lastSender["address"] as? String == "Fixture store Task A shop", "Same provider ID in another task cannot replace Task A's verified snapshot")
        expect(scoped.controller.isCurrent(nativeReply.card!) && nativeReply.card?.purchaseAddress == nativeQuote.senderTitle && nativeQuote.senderTitle.contains("Native shop") && scoped.store.isCurrentWorkbenchQuote(workbenchQuote), "Tool activity preserves native card and independent workbench pricing")
        expect(scoped.store.draft.goods == "Workbench goods" && scoped.store.quotes[0].id == workbenchQuote.id, "Tools never mutate the compatibility workbench projection")

        let queryOnly = PaotuiSession(origin: .task(taskA), authorizationEpoch: nativeSession.authorizationEpoch, credentialScope: scoped.store.chatAccount)
        try queryOnly.replaceDraft(nativeQuote.draft)
        let queryRead = try queryOnly.beginRead(.quote, expected: queryOnly.ticket)
        try queryOnly.acceptQuotes([nativeQuote], for: queryRead)
        _ = try queryOnly.chooseQuote(nativeQuote.id, at: scoped.store.currentTime)
        expect(queryOnly.preparation.inquiryOnly && !queryOnly.canReview(nativeQuote, at: scoped.store.currentTime, unresolved: false), "A query-only Session cannot gain native review permission even with a canonical quote")
        await reject({ _ = try queryOnly.offer(nativeReply.card!) }, "A query-only Session accepted a native conversation card")
        await reject({ _ = try queryOnly.authorizeSubmission(quoteID: nativeQuote.id, at: scoped.store.currentTime, unresolved: false) }, "Query-only origin accepted a submission grant")
        notDispatched(await scoped.store.submitConfirmed(nativeQuote, for: queryOnly.ticket), "A query-only ticket dispatched through the store")
        let toolQuoteID = UUID(uuidString: quoteRows[0]["reference"] as! String)!
        let forgedToolCard = try patch(nativeReply.card!, ["quoteID": toolQuoteID.uuidString])
        await reject({ _ = try await scoped.controller.select(forgedToolCard, .init(action: .confirm), conversationID: nativeID) }, "A tool quote reference replaced native confirmation authority")
        expect(scoped.backend.fixture.submissions.isEmpty && scoped.controller.isCurrent(nativeReply.card!), "Denied query submission attempts do not consume native confirmation")
        let bounded = try PaotuiQueryResult.quotes([nativeQuote], at: scoped.store.currentTime).renderJSON(maxCharacters: 512)
        let boundedObject = try json(bounded)
        expect(bounded.count <= 512 && boundedObject["source"] as? String == "meituan_paotui", "A small bounded projection remains complete parseable source JSON")

        // Even a locally known order's read result belongs to its task revision.
        _ = try await scoped.select(nativeReply, action: .confirm, id: nativeID)
        let statusTask = UUID(), statusGate = scoped.backend.pause("get_order_status")
        let statusInput = #"{"action":"order_status","order_id":"fixture-order-created"}"#
        let oldStatus = Task { try await scoped.store.tool(statusInput, taskID: statusTask) }
        await statusGate.wait()
        let newerRead = try await scoped.store.tool(#"{"action":"addresses"}"#, taskID: statusTask)
        statusGate.release()
        await reject({ _ = try await oldStatus.value }, "Superseded task order-status result was published")
        let newerObject = try json(newerRead)
        expect(newerObject["source"] as? String == "meituan_paotui" && newerObject["kind"] as? String == "addresses", "A late status result cannot replace the newer task query's source result")
        let freshStatus = try json(await scoped.store.tool(statusInput, taskID: statusTask))
        let statusRows = freshStatus["records"] as! [[String: Any]]
        expect(freshStatus["kind"] as? String == "status" && statusRows[0]["status"] as? String == "等待支付", "A fresh explicit status query still returns the locally known order's actual status")
        expect(scoped.backend.fixture.submissions.count == 1, "Status supersession and requery never replay a created order")

        // Core settlement outlives the native UI task's cancellation. Cancel
        // synchronously at the grant notification to reach the otherwise tiny
        // window before the order service's durable-attempt preflight.
        let beforeSend = try CanonicalScenario(root: root), beforeSendID = UUID()
        let beforeSendConfirm = try await beforeSend.confirmation(beforeSend.request(beforeSendID), id: beforeSendID)
        let beforeSendSession = beforeSend.store.session(for: beforeSendID), beforeSendTicket = beforeSendSession.ticket
        let beforeSendQuoteID = beforeSendConfirm.card!.quoteID!
        var beforeSendTask: Task<PaotuiChatReply, Error>?
        var cancelledAtGrant = false
        beforeSendSession.onChange = { [weak beforeSendSession] in
            guard let beforeSendSession, !cancelledAtGrant else { return }
            if case .submitting = beforeSendSession.phase {
                cancelledAtGrant = true; beforeSendTask?.cancel()
            }
        }
        beforeSendTask = Task { try await beforeSend.select(beforeSendConfirm, action: .confirm, id: beforeSendID) }
        await reject({ _ = try await beforeSendTask!.value }, "Cancelled pre-dispatch UI task published a reply")
        beforeSendSession.onChange = nil
        expect(cancelledAtGrant && beforeSend.backend.fixture.submissions.isEmpty && !beforeSend.store.hasUnresolvedSubmission, "Cancellation at grant is actually before the durable attempt and sends no order")
        expect(beforeSendSession.phase == .outcome(quoteID: beforeSendQuoteID, .notDispatched), "A retained Session settles the pre-dispatch cancellation as notDispatched")
        expect(beforeSendSession.currentCard == nil && beforeSend.store.paymentURL == nil && beforeSend.store.message.isEmpty && beforeSend.store.orderStatus.isEmpty && !beforeSend.store.busy, "Pre-dispatch cancellation suppresses UI publication and releases the busy flag")
        let afterBeforeSendQuote = try await beforeSend.store.preview(for: beforeSendTicket)[0]
        expect(beforeSend.store.canSubmit(afterBeforeSendQuote, for: beforeSendTicket), "Pre-dispatch cancellation releases its grant without needing a replacement Session or turn")

        let afterSend = try CanonicalScenario(root: root), afterSendID = UUID()
        let afterSendConfirm = try await afterSend.confirmation(afterSend.request(afterSendID), id: afterSendID)
        let afterSendSession = afterSend.store.session(for: afterSendID), afterSendTicket = afterSendSession.ticket
        let afterSendQuoteID = afterSendConfirm.card!.quoteID!, afterSendGate = afterSend.backend.pause("submit_order")
        let afterSendTask = Task { try await afterSend.select(afterSendConfirm, action: .confirm, id: afterSendID) }
        await afterSendGate.wait()
        expect(afterSend.store.hasUnresolvedSubmission && afterSendSession.phase == .submitting(quoteID: afterSendQuoteID), "The post-dispatch fixture reaches a durable pending attempt before cancellation")
        afterSendTask.cancel(); afterSendGate.release()
        await reject({ _ = try await afterSendTask.value }, "Cancelled dispatched UI task published its late receipt")
        expect(afterSendSession.phase == .outcome(quoteID: afterSendQuoteID, .created) && afterSend.store.lastOrderID == "fixture-order-created" && !afterSend.store.hasUnresolvedSubmission, "A late successful response settles the retained Session and durable original attempt despite cancellation")
        expect(afterSend.backend.fixture.submissions.count == 1 && afterSendSession.currentCard == nil && afterSend.store.paymentURL == nil && afterSend.store.message.isEmpty && afterSend.store.orderStatus.isEmpty && !afterSend.store.busy, "Late cancelled success publishes no receipt/payment UI and sends only once")
        let afterCancelledSendQuote = try await afterSend.store.preview(for: afterSendTicket)[0]
        expect(afterSend.store.canSubmit(afterCancelledSendQuote, for: afterSendTicket), "Post-dispatch cancellation releases its settled grant for a later explicit query in the same Session")

        print("PASS: \(checks) canonical Session/card identity, quote-bound high-fee consent, ABA/lifetime races and task-only query isolation; offline actual-source fixtures only")
    }
}
