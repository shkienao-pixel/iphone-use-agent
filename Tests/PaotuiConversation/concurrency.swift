import Foundation

@MainActor private final class RequestGate {
    private var entered = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true; arrival?.resume(); arrival = nil
        await withCheckedContinuation { release = $0 }
    }
    func wait() async {
        if !entered { await withCheckedContinuation { arrival = $0 } }
    }
    func resume() { release?.resume(); release = nil }
}

@MainActor private final class InterleavedBackend {
    let fixture = Backend()
    var gate: RequestGate?
    var match: ((URLRequest) -> Bool)?
    func client(_ key: String) -> MeituanPaotuiClient {
        MeituanPaotuiClient(credential: key, transport: { request in
            if self.match?(request) == true, let gate = self.gate {
                self.match = nil; self.gate = nil
                await gate.hold()
            }
            let response = try self.fixture.respond(request)
            if request.url?.lastPathComponent == "search_poi" {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let keyword = body["keyword"] as! String
                // Deliberately share an ID while changing metadata, to catch accidental global-cache reads.
                let poi: [String: Any] = ["id": "shared-fixture-shop", "name": keyword, "address": "Fixture store " + keyword,
                    "location": "113.930192,22.512682", "addr_info": [["level_desc": "city", "admin_code": "440300"]]]
                let inner = try JSONSerialization.data(withJSONObject: ["code": 0, "data": ["result": ["pois": [poi]]]])
                let bytes = try JSONSerialization.data(withJSONObject: ["code": 0, "result": "SUCCESS", "data": String(decoding: inner, as: UTF8.self)])
                return (bytes, response.1)
            }
            return response
        })
    }
    func pause(_ endpoint: String, goods: String? = nil) -> RequestGate {
        let pending = RequestGate(); gate = pending
        match = { request in
            guard request.url?.lastPathComponent == endpoint else { return false }
            guard let goods else { return true }
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody!)) as? [String: Any]
            return body?["purchaseGoodDetail"] as? String == goods
        }
        return pending
    }
}

@main struct ConcurrentConversationChecks {
    private static var checks = 0
    private static func expect(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paotui-concurrent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InterleavedBackend(), path = root.appendingPathComponent("orders.json")
        let store = MeituanPaotuiStore(connection: PaotuiFixtureRuntime.connection(), receiptURL: path, clientFactory: backend.client)
        try store.installCredential("offline-concurrent-account")
        let controller = MeituanPaotuiConversation(store: store, planner: { question, _, _ in
            if question == "cancel" { return #"{"intent":"cancel"}"# }
            let recipient = question.hasPrefix("B") ? "Fixture address 2" : "Fixture address 1"
            var body: [String: Any] = ["service": "buy", "goods": question, "nearby": !question.contains("shop"), "recipient": recipient]
            if question.contains("shop") { body["store"] = question }
            return String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        })
        func request(_ id: UUID, _ goods: String) async throws -> PaotuiChatReply {
            try await controller.respond(question: goods, history: [], conversationID: id)
        }
        func quote(_ reply: PaotuiChatReply, _ id: UUID) async throws -> PaotuiChatReply {
            try await controller.select(reply.card!, .init(action: .quote), conversationID: id)
        }
        func confirmCard(_ reply: PaotuiChatReply, _ id: UUID) async throws -> PaotuiChatCard {
            let result = try await controller.select(reply.card!, .init(action: .choose, value: reply.card!.options[0].id), conversationID: id)
            return result.card!
        }
        func reject(_ operation: () async throws -> Void, _ message: String) async {
            do { try await operation(); preconditionFailure(message) } catch { checks += 1 }
        }

        // Existing workbench state remains separate from conversation pricing in both directions.
        try await store.loadAddresses()
        store.draft = PaotuiDraft(service: .buy, recipientID: "address:1", nearby: true, goods: "Workbench")
        let workbench = try await store.preview()[0]
        let a = UUID(), b = UUID()
        let aCard = try await confirmCard(quote(request(a, "A original"), a), a)
        let bCard = try await confirmCard(quote(request(b, "B original"), b), b)
        expect(controller.isCurrent(aCard) && controller.isCurrent(bCard), "Two conversations retain their actual valid quote cards")
        expect(aCard.canCreateOrder && bCard.canCreateOrder, "Both independent confirmation cards are enabled")
        expect(store.draft.goods == "Workbench" && store.quotes.first?.id == workbench.id && store.isCurrentWorkbenchQuote(workbench), "Conversation pricing does not overwrite workbench draft or quote authority")
        store.draft.goods = "Workbench changed"
        expect(controller.isCurrent(aCard) && controller.isCurrent(bCard), "Workbench edits cannot invalidate conversation quotes")
        let firstReceipt = try await controller.select(aCard, .init(action: .confirm), conversationID: a)
        expect(firstReceipt.card?.kind == "receipt" && backend.fixture.submissions.count == 1, "A still submits its original quote after B pricing")
        expect(backend.fixture.submissions[0]["purchaseGoodDetail"] as? String == "A original", "A submits only its own exact goods")
        expect(controller.isCurrent(bCard), "A success does not discard B quote authority")
        _ = try await controller.select(bCard, .init(action: .confirm), conversationID: b)
        expect(backend.fixture.submissions.count == 2 && backend.fixture.submissions[1]["purchaseGoodDetail"] as? String == "B original", "B subsequently submits only B goods")
        await reject({ _ = try await controller.select(aCard, .init(action: .confirm), conversationID: a) }, "Consumed A quote replayed")

        // B is waiting on a real production preview call while A is edited and repriced.
        let c = UUID(), d = UUID()
        let oldC = try await confirmCard(quote(request(c, "A before edit"), c), c)
        let dRequest = try await request(d, "B in flight")
        let gate = backend.pause("delivery_preview", goods: "B in flight")
        let dWork = Task { try await quote(dRequest, d) }
        await gate.wait()
        let newC = try await confirmCard(quote(request(c, "A after edit"), c), c)
        expect(!controller.isCurrent(oldC) && controller.isCurrent(newC), "A edit revokes only its own former quote")
        gate.resume()
        let dQuote = try await dWork.value
        let dCard = try await confirmCard(dQuote, d)
        expect(dCard.goods == "B in flight" && controller.isCurrent(dCard) && controller.isCurrent(newC), "B late preview cannot overwrite A or adopt A draft")
        await reject({ _ = try await controller.select(oldC, .init(action: .confirm), conversationID: c) }, "Edited quote accepted")

        // A newer human request supersedes an in-flight response in the same conversation.
        let e = UUID(), eRequest = try await request(e, "B superseded")
        let oldGate = backend.pause("delivery_preview", goods: "B superseded")
        let oldWork = Task { try await quote(eRequest, e) }
        await oldGate.wait()
        let replacement = try await request(e, "B replacement")
        oldGate.resume()
        await reject({ _ = try await oldWork.value }, "Late old quote replaced the new request")
        expect(controller.isCurrent(replacement.card!) && replacement.card?.goods == "B replacement", "Late response leaves replacement card current")
        let replacementCard = try await confirmCard(quote(replacement, e), e)
        expect(replacementCard.goods == "B replacement" && controller.isCurrent(replacementCard), "Replacement can obtain its own fresh quote")

        // Merchant searches return each request's own result, even if another cache entry has the same ID.
        let shopA = UUID(), shopB = UUID()
        let aPlaces = try await request(shopA, "A shop")
        let shopGate = backend.pause("search_poi")
        let bSearch = Task { try await request(shopB, "B shop") }
        await shopGate.wait()
        let aSelected = try await controller.select(aPlaces.card!, .init(action: .choose, value: aPlaces.card!.options[0].id), conversationID: shopA)
        let aShopCard = try await confirmCard(quote(aSelected, shopA), shopA)
        shopGate.resume()
        let bPlaces = try await bSearch.value
        expect(aPlaces.card?.options[0].title == "A shop" && bPlaces.card?.options[0].title == "B shop", "Overlapping searches return request-bound merchant choices")
        let bSelected = try await controller.select(bPlaces.card!, .init(action: .choose, value: bPlaces.card!.options[0].id), conversationID: shopB)
        let bShopCard = try await confirmCard(quote(bSelected, shopB), shopB)
        let aReopened = try await controller.select(aShopCard, .init(action: .review), conversationID: shopA)
        expect(aReopened.card?.purchaseAddress.contains("A shop") == true && aReopened.card?.purchaseAddress.contains("B shop") == false,
               "A review keeps its verified merchant snapshot after B replaces the shared cache ID")
        expect(bShopCard.purchaseAddress.contains("B shop") && controller.isCurrent(bShopCard), "B independently retains its own merchant snapshot")

        // Cancellation and credential replacement revoke the waiting request, not another conversation.
        let f = UUID(), fRequest = try await request(f, "B cancelled")
        let cancelGate = backend.pause("delivery_preview", goods: "B cancelled")
        let cancelled = Task { try await quote(fRequest, f) }
        await cancelGate.wait(); cancelled.cancel(); cancelGate.resume()
        await reject({ _ = try await cancelled.value }, "Cancelled preview became a quote")
        expect(controller.isCurrent(newC), "Cancelling B leaves A valid")
        let userCancelledID = UUID(), userCancelledRequest = try await request(userCancelledID, "B user cancel")
        let userCancelGate = backend.pause("delivery_preview", goods: "B user cancel")
        let userCancelledWork = Task { try await quote(userCancelledRequest, userCancelledID) }
        await userCancelGate.wait()
        _ = try await request(userCancelledID, "cancel")
        userCancelGate.resume()
        await reject({ _ = try await userCancelledWork.value }, "Explicit user cancellation allowed an old response")
        expect(!controller.isCurrent(userCancelledRequest.card!) && controller.isCurrent(newC), "User cancellation removes only its own request authority")
        let g = UUID(), gRequest = try await request(g, "B account changed")
        let authGate = backend.pause("delivery_preview", goods: "B account changed")
        let authWork = Task { try await quote(gRequest, g) }
        await authGate.wait(); try store.installCredential("offline-new-account"); authGate.resume()
        await reject({ _ = try await authWork.value }, "Old account response became current")
        expect(!controller.isCurrent(newC) && !controller.isCurrent(dCard), "Credential changes revoke every old account quote")

        // Keep a global submission lock and durable unknown-result protection across scopes.
        let h = UUID(), i = UUID()
        let hCard = try await confirmCard(quote(request(h, "A locked submit"), h), h)
        let iCard = try await confirmCard(quote(request(i, "B locked submit"), i), i)
        let submitGate = backend.pause("submit_order")
        let submission = Task { try await controller.select(hCard, .init(action: .confirm), conversationID: h) }
        await submitGate.wait()
        expect(store.busy && store.hasUnresolvedSubmission, "Global lock and durable pending precede the submit attempt")
        expect(controller.isCurrent(iCard) && !controller.presentation(for: iCard, conversationID: i).canCreateOrder, "Another current card cannot confirm while submission is pending")
        await reject({ _ = try await controller.select(iCard, .init(action: .confirm), conversationID: i) }, "Parallel order bypassed submit lock")
        submitGate.resume(); _ = try await submission.value
        expect(controller.isCurrent(iCard), "Successful submission releases the lock without destroying another quote")
        backend.fixture.failSubmit = true
        _ = try await controller.select(iCard, .init(action: .confirm), conversationID: i)
        expect(store.hasUnresolvedSubmission && backend.fixture.submissions.count == 4, "Failed response retains one global pending receipt")
        await reject({ _ = try await controller.select(iCard, .init(action: .confirm), conversationID: i) }, "Unknown submit was retried")
        let j = UUID(), pendingQuote = try await quote(request(j, "A read-only pricing"), j)
        expect(pendingQuote.card?.canCreateOrder == false && pendingQuote.card?.deliveryFee != nil, "Read-only pricing remains available with global unresolved submission")
        let pendingCard = try await confirmCard(pendingQuote, j)
        await reject({ _ = try await controller.select(pendingCard, .init(action: .confirm), conversationID: j) }, "Another conversation bypassed unknown-result protection")
        let restored = MeituanPaotuiStore(connection: PaotuiFixtureRuntime.connection(), receiptURL: path, clientFactory: backend.client)
        expect(restored.hasUnresolvedSubmission && restored.lastOrderID != nil, "Existing receipt schema reopens with successful and pending orders intact")
        let restarted = MeituanPaotuiConversation(store: restored)
        expect(!restarted.isCurrent(pendingCard), "Persisted cards cannot reconstruct runtime quote authority")

        // A failed review write must not advance pricing authority or discard a valid read-only response.
        let failedReviewStore = MeituanPaotuiStore(connection: PaotuiFixtureRuntime.connection(), receiptURL: path, clientFactory: backend.client,
            commitJournal: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        try await failedReviewStore.loadAddresses()
        let failedReviewContext = try failedReviewStore.beginConversationRequest(UUID(),
            draft: PaotuiDraft(service: .buy, recipientID: "address:1", nearby: true, goods: "B failed review pricing"))
        let failedReviewGate = backend.pause("delivery_preview", goods: "B failed review pricing")
        let pricingAcrossFailedReview = Task { try await failedReviewStore.preview(for: failedReviewContext) }
        await failedReviewGate.wait()
        do {
            try failedReviewStore.recordReview(attemptID: failedReviewStore.pendingReviews[0].id, conclusion: .believesNotCreated)
            preconditionFailure("Failed review write removed the unknown barrier")
        } catch { checks += 1 }
        failedReviewGate.resume()
        let readOnlyAfterFailure = try await pricingAcrossFailedReview.value[0]
        expect(failedReviewStore.hasUnresolvedSubmission && failedReviewStore.owns(readOnlyAfterFailure, for: failedReviewContext) &&
               !failedReviewStore.canSubmit(readOnlyAfterFailure, for: failedReviewContext),
               "Failed review persistence preserves in-flight read-only pricing and its global submission barrier")

        // A successful human review revokes previews that began before it, including a global preview.
        var reviewDraft = PaotuiDraft(service: .buy, recipientID: "address:1", goods: "B scoped review pricing")
        var reviewContext = try store.beginConversationRequest(UUID(), draft: reviewDraft)
        let reviewPlace = try await store.search(keyword: "A review shop", city: "深圳", for: reviewContext)[0]
        reviewDraft.senderID = reviewPlace.id
        reviewContext = try store.updateConversationDraft(reviewDraft, for: reviewContext)
        let scopedReviewGate = backend.pause("delivery_preview", goods: "B scoped review pricing")
        let pricingAcrossReview = Task { try await store.preview(for: reviewContext) }
        await scopedReviewGate.wait()
        store.draft = PaotuiDraft(service: .buy, recipientID: "address:1", nearby: true, goods: "B global review pricing")
        let globalReviewGate = backend.pause("delivery_preview", goods: "B global review pricing")
        let globalPricingAcrossReview = Task { try await store.preview() }
        await globalReviewGate.wait()
        try store.recordReview(attemptID: store.pendingReviews[0].id, conclusion: .believesNotCreated)
        expect(store.isCurrent(reviewContext) && store.locations(for: reviewContext).contains { $0.id == reviewPlace.id } &&
               store.draft.goods == "B global review pricing", "Review preserves preparation scopes, drafts and verified places")
        scopedReviewGate.resume(); globalReviewGate.resume()
        await reject({ _ = try await pricingAcrossReview.value }, "Scoped pre-review response restored order authority")
        await reject({ _ = try await globalPricingAcrossReview.value }, "Global pre-review response restored order authority")
        expect(store.quotes.isEmpty, "Rejected global preview cannot publish stale stored quotes after review")
        let activeReviewQuote = try await store.preview(for: reviewContext)[0]
        expect(store.owns(activeReviewQuote, for: reviewContext) && store.canSubmit(activeReviewQuote, for: reviewContext),
               "A new explicit scoped query after review can price the preserved draft and place")
        let activeGlobalQuote = try await store.preview()[0]
        expect(store.isCurrentWorkbenchQuote(activeGlobalQuote), "A new explicit global query after review receives fresh pricing authority")
        expect(!store.hasUnresolvedSubmission && !controller.isCurrent(pendingCard), "Human review requires new scoped quotes, never reuses old pending cards")
        expect(backend.fixture.submissions.count == 4, "No cancellation, refresh, restart or human review replayed an order")
        backend.fixture.failSubmit = false
        let canonicalContext = try store.beginConversationRequest(UUID(), draft: PaotuiDraft(service: .buy, recipientID: "address:1", nearby: true, goods: "Canonical goods"))
        let canonical = try await store.preview(for: canonicalContext)[0]
        let canonicalSession = store.session(for: canonicalContext.origin.conversationID!)
        _ = try canonicalSession.chooseQuote(canonical.id, at: store.currentTime)
        var canonicalCard = PaotuiChatCard(conversationID: canonicalContext.origin.conversationID!, kind: "confirm", title: "Fixture confirmation")
        canonicalCard.quoteID = canonical.id; canonicalCard.canCreateOrder = true
        let offeredCanonicalCard = try canonicalSession.offer(canonicalCard)
        _ = try canonicalSession.consumeCard(offeredCanonicalCard)
        var forgedPayload = canonical.request; forgedPayload["purchaseGoodDetail"] = "Caller replacement"
        let forged = PaotuiQuote(id: canonical.id, draft: canonical.draft, senderTitle: canonical.senderTitle, recipientTitle: canonical.recipientTitle,
            serviceTitle: canonical.serviceTitle, distance: canonical.distance, estimate: canonical.estimate, fee: 0, originalFee: 0,
            goodsPaymentNote: canonical.goodsPaymentNote, quotedAt: canonical.quotedAt, agreementURL: canonical.agreementURL,
            agreementTitle: canonical.agreementTitle, account: canonical.account, request: forgedPayload, orderToken: "caller-token", couponViewID: "")
        await store.submitConfirmed(forged, for: canonicalContext)
        expect(backend.fixture.submissions.last?["purchaseGoodDetail"] as? String == "Canonical goods" &&
               backend.fixture.submissions.last?["orderToken"] as? String == canonical.orderToken,
               "Scoped submission resolves the actual stored quote, never caller-replaced payload or token")
        expect(backend.fixture.submissions.last?["previewTotal"] as? String == String(canonical.fee), "Stored quote fees remain canonical through dispatch")

        func savedReceipt(_ card: PaotuiChatCard) throws -> [String: Any]? {
            let journal = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
            let rows = journal["receipts"] as! [[String: Any]]
            return rows.last { ($0["quoteID"] as? String)?.lowercased() == card.quoteID!.uuidString.lowercased() }
        }
        // Once dispatch may have happened, stale UI ownership must not erase the durable response.
        let accountID = UUID(), accountCard = try await confirmCard(quote(request(accountID, "A prior account order"), accountID), accountID)
        let accountSubmitGate = backend.pause("submit_order")
        let accountSubmit = Task { try await controller.select(accountCard, .init(action: .confirm), conversationID: accountID) }
        await accountSubmitGate.wait()
        try store.installCredential("offline-after-submission-account")
        accountSubmitGate.resume()
        do { _ = try await accountSubmit.value; preconditionFailure("Old-account submit reply replaced current state") }
        catch {
            expect(error.localizedDescription.contains("原美团账号") && error.localizedDescription.contains("勿重复下单"),
                   "Account change after dispatch explicitly directs verification in the original account")
        }
        expect(try savedReceipt(accountCard)?["state"] as? String == "created", "Successful old-account response remains durably recorded after credential replacement")
        expect(!controller.isCurrent(accountCard), "An old-account confirmation cannot be reused")

        let changedID = UUID(), changedCard = try await confirmCard(quote(request(changedID, "A submitted old request"), changedID), changedID)
        let changedSubmitGate = backend.pause("submit_order")
        let changedSubmit = Task { try await controller.select(changedCard, .init(action: .confirm), conversationID: changedID) }
        await changedSubmitGate.wait()
        let changedRequest = try await request(changedID, "A replacement during submit")
        changedSubmitGate.resume()
        do { _ = try await changedSubmit.value; preconditionFailure("Late submit response replaced new user request") }
        catch {
            expect(error.localizedDescription.contains("核对这次结果") && error.localizedDescription.contains("新需求没有自动提交"),
                   "A changed request receives an explicit no-repeat warning after the previous submission settles")
        }
        expect(controller.isCurrent(changedRequest.card!) && changedRequest.card?.goods == "A replacement during submit",
               "Late submission cannot replace the newer conversation card")
        expect(try savedReceipt(changedCard)?["state"] as? String == "created", "New conversation intent cannot erase the prior order receipt")
        expect(backend.fixture.submissions.last?["purchaseGoodDetail"] as? String == "A submitted old request", "Changing intent during submit never changes an already dispatched order payload")

        let cancelSubmitID = UUID(), cancelSubmitCard = try await confirmCard(quote(request(cancelSubmitID, "A cancelled after dispatch"), cancelSubmitID), cancelSubmitID)
        let cancelledSubmitGate = backend.pause("submit_order")
        let cancelledSubmit = Task { try await controller.select(cancelSubmitCard, .init(action: .confirm), conversationID: cancelSubmitID) }
        await cancelledSubmitGate.wait(); cancelledSubmit.cancel(); cancelledSubmitGate.resume()
        await reject({ _ = try await cancelledSubmit.value }, "Cancelled host request published a late receipt card")
        expect(try savedReceipt(cancelSubmitCard)?["state"] as? String == "created", "Cancellation after dispatch preserves the real successful receipt before propagating cancellation")

        backend.fixture.failSubmit = true
        let unknownAccountID = UUID(), unknownAccountCard = try await confirmCard(quote(request(unknownAccountID, "A unknown original account"), unknownAccountID), unknownAccountID)
        let unknownAccountGate = backend.pause("submit_order")
        let unknownAccountSubmit = Task { try await controller.select(unknownAccountCard, .init(action: .confirm), conversationID: unknownAccountID) }
        await unknownAccountGate.wait(); try store.installCredential("offline-after-unknown-account"); unknownAccountGate.resume()
        do { _ = try await unknownAccountSubmit.value; preconditionFailure("Unknown old-account response was adopted") }
        catch {
            expect(error.localizedDescription.contains("原美团账号") && error.localizedDescription.contains("勿重复下单"),
                   "An unknown outcome after account change retains the original-account no-repeat instruction")
        }
        let unknownState = try savedReceipt(unknownAccountCard)?["state"] as? String
        expect(store.hasUnresolvedSubmission && unknownState == "unknown",
               "Unknown submission remains durably pending and blocks every account")
        let afterUnknownID = UUID(), afterUnknown = try await quote(request(afterUnknownID, "B after unknown account"), afterUnknownID)
        expect(afterUnknown.card?.canCreateOrder == false && afterUnknown.card?.deliveryFee != nil,
               "New-account pricing can continue without restoring order authority")
        let afterUnknownCard = try await confirmCard(afterUnknown, afterUnknownID)
        await reject({ _ = try await controller.select(afterUnknownCard, .init(action: .confirm), conversationID: afterUnknownID) }, "Credential change bypassed a dispatched unknown order")
        expect(backend.fixture.submissions.count == 9, "Late results, edits, cancellations and credential changes do not cause automatic submission retries")
        expect(MeituanPaotuiStore(connection: PaotuiFixtureRuntime.connection(), receiptURL: path, clientFactory: backend.client).hasUnresolvedSubmission, "Restart retains the unresolved old-account submission")
        print("PASS: \(checks) production multi-conversation pricing, interleaved responses, workbench isolation, credential/cancel invalidation and global submission protections; synthetic transport only")
    }
}
