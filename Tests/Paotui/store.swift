import Foundation

@MainActor final class Backend {
    var submissions: [[String:Any]] = []
    var previews: [[String:Any]] = []
    var failSubmit = false
    func client(_ key: String) -> MeituanPaotuiClient {
        MeituanPaotuiClient(credential:key,transport:{ request in try self.respond(request) })
    }
    func respond(_ request: URLRequest) throws -> (Data,HTTPURLResponse) {
        let path=request.url!.lastPathComponent
        let payload=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
        let data:[String:Any]
        switch path {
        case "get_address_list":
            data=["userAddresses":(1...2).map { ["id":$0,"address":"Fixture address \($0)","houseNumber":"101","name":"Test","phone":"138****0000","latitude":22518481+$0,"longitude":113935456+$0,"bmCityId":440300,"lastUseTime":$0] as [String:Any] }]
        case "get_address_info_by_id": data=["id":payload["addressId"]!,"phone":"13800000000"]
        case "delivery_preview":
            previews.append(payload)
            let service=payload["serviceType"] as? Int ?? 0
            data=["deliveryFeeView":["totalAmount":service == 4033 ? 23.0 : 18.0],"total":service == 4033 ? 23.0 : 18.0,"orderToken":"fixture-token-\(service)","distanceDesc":"1.3公里","estimateDeliveryTimeText":"Fixture estimate","couponPreviewView":["amount":0]]
        case "submit_order":
            submissions.append(payload)
            if failSubmit { throw URLError(.networkConnectionLost) }
            data=["orderId":"fixture-order-created","tradeNo":"fixture-trade","payToken":"fixture-payment"]
        case "get_order_status": data=["statusDesc":"等待支付"]
        default: fatalError("Unexpected request: "+path)
        }
        let inner=try JSONSerialization.data(withJSONObject:["code":0,"data":data])
        let bytes=try JSONSerialization.data(withJSONObject:["code":0,"result":"SUCCESS","data":String(data:inner,encoding:.utf8)!])
        return (bytes,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
    }
}
@main struct StoreChecks {
    static var checks=0
    static func expect(_ value:Bool,_ label:String){checks+=1;precondition(value,label)}
    @MainActor static func main() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("paotui-store-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let backend=Backend();let path=root.appendingPathComponent("orders.json")
        let store=MeituanPaotuiStore(connection: PaotuiFixtureRuntime.connection(), receiptURL:path,clientFactory:backend.client)
        try store.installCredential("fixture-authorized-key")
        try await store.loadAddresses()
        store.draft=PaotuiDraft(service:.buy,recipientID:"address:1",senderID:"address:2",nearby:true,goods:"文件",category:.document)
        store.selectService(.send)
        expect(!store.draft.nearby && store.draft.senderID.isEmpty && store.draft.recipientID == "address:1", "Service switch resets the purchase mode and source address without losing destination")
        store.draft.senderID="address:2"
        expect(store.draft.weight == nil && store.draft.missingFields == [.weight], "Selecting send preserves unknown actual weight until supplied")
        store.draft.weight=0.5
        let nativeRequest = try store.beginConversationRequest(UUID(), draft: store.draft)
        let quotes=try await store.preview(for: nativeRequest)
        expect(quotes.count==2,"Normal and express quotes")
        expect(backend.previews[0]["serviceType"] as? Int==1003 && backend.previews[1]["serviceType"] as? Int==4033,"Correct service contracts")
        let goods=backend.previews[0]["goods"] as! [String:Any]
        expect(goods["goodTypes"] as? [Int]==[4] && goods["goodTypeNames"] as? [String]==["文件"],"Document category mapped as a pair")
        expect(backend.previews[0]["goodsInfo"] as? String != nil,"Official goodsInfo wire contract")
        let express=quotes[1]
        try PaotuiFixtureRuntime.confirmNativeQuote(express, in: store, request: nativeRequest)
        await store.submitConfirmed(express, for: nativeRequest)
        expect(backend.submissions.count==1,"Single confirmed submit")
        let sent=backend.submissions[0]
        expect(sent["serviceType"] as? Int==4033 && sent["orderToken"] as? String=="fixture-token-4033","Express uses its own token")
        expect(sent["deliveryFee"] as? String=="23.0" && sent["previewTotal"] as? String=="23.0","Express uses its own fees")
        expect(store.lastOrderID=="fixture-order-created" && !store.hasUnresolvedSubmission,"Success is durably recorded")
        expect(store.orderURL(quoteID:express.id)?.lastPathComponent == "fixture-order-created" && store.orderURL(quoteID:UUID()) == nil,"Conversation receipt belongs only to its actual quote, never an earlier order")
        await store.submitConfirmed(express, for: nativeRequest)
        expect(backend.submissions.count==1,"Repeated old quote cannot resubmit")
        let status=try await store.status(orderID:"fixture-order-created")
        expect(status=="等待支付","Read actual status without assuming payment")
        let restored=MeituanPaotuiStore(connection: PaotuiFixtureRuntime.connection(), receiptURL:path,clientFactory:backend.client)
        expect(restored.lastOrderID=="fixture-order-created","Receipt survives relaunch")
        let blockedDirectory=root.appendingPathComponent("not-a-folder");try Data("fixture".utf8).write(to:blockedDirectory)
        let blocked=MeituanPaotuiStore(connection: PaotuiFixtureRuntime.connection(), receiptURL:blockedDirectory.appendingPathComponent("orders.json"),clientFactory:backend.client)
        try await blocked.loadAddresses()
        blocked.draft=PaotuiDraft(service:.buy,recipientID:"address:1",nearby:true,goods:"水一瓶")
        let blockedRequest = try blocked.beginConversationRequest(UUID(), draft: blocked.draft)
        let unsaved=try await blocked.preview(for: blockedRequest)[0]
        try PaotuiFixtureRuntime.confirmNativeQuote(unsaved, in: blocked, request: blockedRequest)
        await blocked.submitConfirmed(unsaved, for: blockedRequest)
        expect(backend.submissions.count==1 && blocked.failed && blocked.message.contains("订单记录保存失败"),"Local write failure is diagnosed before the submit endpoint is called")
        expect(blocked.orderURL(quoteID:unsaved.id)==nil,"Failed local preparation cannot show another order's receipt")
        let failingBackend=Backend();failingBackend.failSubmit=true
        let pendingPath=root.appendingPathComponent("pending.json")
        let uncertain=MeituanPaotuiStore(connection: PaotuiFixtureRuntime.connection(), receiptURL:pendingPath,clientFactory:failingBackend.client)
        try await uncertain.loadAddresses()
        uncertain.draft=PaotuiDraft(service:.buy,recipientID:"address:1",nearby:true,goods:"饮料一瓶")
        let uncertainRequest = try uncertain.beginConversationRequest(UUID(), draft: uncertain.draft)
        let buy=try await uncertain.preview(for: uncertainRequest)[0]
        try PaotuiFixtureRuntime.confirmNativeQuote(buy, in: uncertain, request: uncertainRequest)
        await uncertain.submitConfirmed(buy, for: uncertainRequest)
        expect(uncertain.hasUnresolvedSubmission && failingBackend.submissions.count==1,"Lost response remains pending")
        await uncertain.submitConfirmed(buy, for: uncertainRequest)
        expect(failingBackend.submissions.count==1,"No retry after lost response")
        let afterCrash=MeituanPaotuiStore(connection: PaotuiFixtureRuntime.connection(), receiptURL:pendingPath,clientFactory:failingBackend.client)
        expect(afterCrash.hasUnresolvedSubmission,"Pending survives app crash")
        expect(afterCrash.pendingReviews.first?.requestSummary == "帮买" && afterCrash.pendingReviews.first?.deliveryFee == 18,
               "Unknown attempts retain a safe service/category summary and quoted courier fee for human reconciliation")
        try afterCrash.disconnect();try afterCrash.installCredential("another-fixture-key")
        expect(afterCrash.hasUnresolvedSubmission,"Logout/new credential cannot bypass pending")
        let disk=try String(contentsOf:pendingPath,encoding:.utf8)
        expect(!disk.contains("13800000000") && !disk.contains("fixture-token-") && !disk.contains("fixture-authorized-key"),"Durable receipts contain no phones or secrets")
        try afterCrash.recordReview(attemptID: afterCrash.pendingReviews[0].id, conclusion: .believesNotCreated)
        expect(!afterCrash.hasUnresolvedSubmission,"Explicit human review unlocks a fresh query")
        let corrupted=root.appendingPathComponent("corrupt.json");try Data("bad".utf8).write(to:corrupted)
        let unreadable=MeituanPaotuiStore(connection: PaotuiFixtureRuntime.connection(), receiptURL:corrupted,clientFactory:backend.client)
        expect(unreadable.hasUnresolvedSubmission,"Unreadable receipts fail closed")
        let corruptBytes = try Data(contentsOf: corrupted)
        do { try unreadable.recordReview(attemptID: UUID(), conclusion: .believesNotCreated); preconditionFailure("Corrupt log review bypassed the barrier") } catch { checks += 1 }
        expect(try Data(contentsOf: corrupted) == corruptBytes && unreadable.hasUnresolvedSubmission, "Corrupt logs remain unchanged and blocked")

        let journal = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        expect(journal["schemaVersion"] as? Int == 3 && (journal["receipts"] as? [[String: Any]])?.count == 1,
               "New journal is versioned and atomically replaced from pending to created")
        expect(try path.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
               "Committed file retains the staging file backup exclusion metadata")

        let reviewPath = root.appendingPathComponent("legacy-review.json")
        let firstID = UUID(), secondID = UUID()
        let legacyRows: [[String: Any]] = [firstID, secondID].map {
            ["quoteID": $0.uuidString, "account": "previous-authorization", "state": "pending", "createdAt": Date().timeIntervalSinceReferenceDate]
        }
        try JSONSerialization.data(withJSONObject: legacyRows).write(to: reviewPath)
        let callsBeforeReview = backend.submissions.count
        let reviewStore = MeituanPaotuiStore(connection: PaotuiFixtureRuntime.connection(), receiptURL: reviewPath, clientFactory: backend.client)
        expect(reviewStore.hasUnresolvedSubmission && reviewStore.pendingReviews.count == 2, "Both legacy pending rows migrate to unknown and preserve the global barrier")
        expect(Set(reviewStore.pendingReviews.map(\.id)) == Set([firstID, secondID]), "Legacy attempt identities are stable across migration")
        expect(reviewStore.pendingReviews.allSatisfy { !$0.isCurrentAuthorization && $0.reviewedAt == nil }, "Recovery projection marks prior authorization without exposing credentials")
        expect(reviewStore.pendingReviews.allSatisfy { $0.requestSummary == nil && $0.deliveryFee == nil }, "Migration leaves missing historical request summaries and fees unknown")
        let migrated = try JSONSerialization.jsonObject(with: Data(contentsOf: reviewPath)) as! [String: Any]
        let migratedRows = migrated["receipts"] as! [[String: Any]]
        expect(migrated["schemaVersion"] as? Int == 3 && migratedRows.allSatisfy { $0["state"] as? String == "unknown" }, "Legacy arrays are durably migrated without replays or invented platform state")

        try reviewStore.recordReview(attemptID: firstID, conclusion: .stillUnknown)
        expect(reviewStore.hasUnresolvedSubmission && reviewStore.pendingReviews.count == 2, "Still unknown never unlocks either pending submission")
        let latestReview = reviewStore.pendingReviews.first { $0.id == firstID }!
        expect(latestReview.lastConclusion == .stillUnknown && latestReview.reviewedAt != nil && latestReview.reviewSource == "user_report_in_sela", "Review records its human conclusion, date and source")
        let unknownRestart = MeituanPaotuiStore(connection: PaotuiFixtureRuntime.connection(), receiptURL: reviewPath, clientFactory: backend.client)
        expect(unknownRestart.pendingReviews.first { $0.id == firstID }?.lastConclusion == .stillUnknown && unknownRestart.hasUnresolvedSubmission,
               "Still-unknown review and barrier survive restart")

        let beforeFailedReview = try Data(contentsOf: reviewPath)
        var stagedCommitAttempts = 0
        let failingReview = MeituanPaotuiStore(connection: PaotuiFixtureRuntime.connection(), receiptURL: reviewPath, clientFactory: backend.client, commitJournal: { staged, destination in
            stagedCommitAttempts += 1
            expect(staged.deletingLastPathComponent() == destination.deletingLastPathComponent() && FileManager.default.fileExists(atPath: staged.path), "Journal stages a complete same-directory file before committing")
            expect(try staged.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true, "Backup exclusion succeeds before the journal commit")
            throw CocoaError(.fileWriteNoPermission)
        })
        do { try failingReview.recordReview(attemptID: firstID, conclusion: .believesNotCreated); preconditionFailure("Failed journal commit unlocked submission") } catch { checks += 1 }
        expect(stagedCommitAttempts == 1 && failingReview.hasUnresolvedSubmission && failingReview.pendingReviews.count == 2,
               "Commit failure leaves the in-memory unknown records and global barrier intact")
        expect(try Data(contentsOf: reviewPath) == beforeFailedReview, "Failed review leaves the previous journal byte-for-byte intact")
        expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".paotui-orders-") }, "Failed journal staging is cleaned up without deleting the old journal")

        try reviewStore.recordReview(attemptID: firstID, conclusion: .believesCreated)
        expect(reviewStore.hasUnresolvedSubmission && reviewStore.pendingReviews.map(\.id) == [secondID], "Reviewing one submission never clears another pending record")
        expect(reviewStore.lastOrderID == nil && reviewStore.orderURL(quoteID: firstID) == nil, "Human belief creates no platform order ID, payment state or fabricated deep link")
        do { try reviewStore.recordReview(attemptID: firstID, conclusion: .believesNotCreated); preconditionFailure("Stale review changed an already resolved row") } catch { checks += 1 }
        try reviewStore.recordReview(attemptID: secondID, conclusion: .believesNotCreated)
        expect(!reviewStore.hasUnresolvedSubmission && reviewStore.pendingReviews.isEmpty, "Only a successful explicit review of the final pending record removes the barrier")
        let reviewedJournal = try JSONSerialization.jsonObject(with: Data(contentsOf: reviewPath)) as! [String: Any]
        let reviewedRows = reviewedJournal["receipts"] as! [[String: Any]]
        expect(reviewedRows.allSatisfy { $0["state"] as? String == "reviewed" && $0["orderID"] == nil }, "Human-reviewed records stay distinct from provider-created orders")
        expect((reviewedRows[0]["reviews"] as? [[String: Any]])?.count == 2, "Earlier still-unknown reviews remain in the audit trail")
        expect(backend.submissions.count == callsBeforeReview, "Migration, restart, review and failed writes never replay an order")

        let historyPath = root.appendingPathComponent("legacy-history.json")
        let historicalCreatedID = UUID(), historicalReviewedID = UUID()
        let legacyHistory: [[String: Any]] = [
            ["quoteID": historicalCreatedID.uuidString, "account": reviewStore.chatAccount, "state": "created",
             "orderID": "historical-real-order", "createdAt": Date().timeIntervalSinceReferenceDate],
            ["quoteID": historicalReviewedID.uuidString, "account": reviewStore.chatAccount, "state": "reviewed",
             "createdAt": Date().timeIntervalSinceReferenceDate]
        ]
        try JSONSerialization.data(withJSONObject: legacyHistory).write(to: historyPath)
        let historicalStore = MeituanPaotuiStore(connection: PaotuiFixtureRuntime.connection(), receiptURL: historyPath, clientFactory: backend.client)
        let historicalJournal = try JSONSerialization.jsonObject(with: Data(contentsOf: historyPath)) as! [String: Any]
        let historicalRows = historicalJournal["receipts"] as! [[String: Any]]
        expect(!historicalStore.hasUnresolvedSubmission && historicalStore.lastOrderID == "historical-real-order",
               "Legacy created and reviewed records retain their distinct settled meanings after migration")
        expect(historicalRows[0]["state"] as? String == "created" && historicalRows[0]["orderID"] as? String == "historical-real-order" &&
               historicalStore.orderURL(quoteID: historicalCreatedID)?.lastPathComponent == "historical-real-order",
               "Migration preserves an actual historical provider order ID and its order link")
        expect(historicalRows[1]["state"] as? String == "reviewed" && historicalRows[1]["orderID"] == nil &&
               historicalRows.allSatisfy { ($0["reviews"] as? [[String: Any]])?.isEmpty == true },
               "Legacy reviewed rows never acquire a made-up provider ID, human conclusion, date or review source")
        expect(backend.submissions.count == callsBeforeReview, "Migrating historical created/reviewed rows performs no order submission")

        let futurePath = root.appendingPathComponent("future.json")
        let futureBytes = try JSONSerialization.data(withJSONObject: ["schemaVersion": 99, "receipts": migratedRows])
        try futureBytes.write(to: futurePath)
        let future = MeituanPaotuiStore(connection: PaotuiFixtureRuntime.connection(), receiptURL: futurePath, clientFactory: backend.client)
        expect(future.hasUnresolvedSubmission && !future.orderReviewAvailable, "Unknown schema versions fail closed without pretending the empty projection is safe")
        do { try future.recordReview(attemptID: firstID, conclusion: .believesNotCreated); preconditionFailure("Future-schema review bypassed the barrier") } catch { checks += 1 }
        expect(try Data(contentsOf: futurePath) == futureBytes, "Future-schema journals are never silently rewritten")

        let toolTaskID = UUID()
        let previewRequestsBefore = backend.previews.count
        for query in [
            #"{"action":"preview_send","recipient":"address:1","sender":"address:2","goods":"文件","category":"document"}"#,
            #"{"action":"preview_send","recipient":"address:1","sender":"address:2","goods":"文件","weight":2}"#
        ] {
            do { _ = try await store.tool(query, taskID: toolTaskID); preconditionFailure("Incomplete send query reached preview") } catch { checks += 1 }
        }
        expect(backend.previews.count == previewRequestsBefore, "Tool sends without explicit weight/category are rejected before any preview request")
        _ = try await store.tool(#"{"action":"addresses"}"#, taskID: toolTaskID)
        _ = try await store.tool(#"{"action":"preview_buy","recipient":"address:1","nearby":true,"goods":"水一瓶"}"#, taskID: toolTaskID)
        expect(backend.previews.count == previewRequestsBefore + 1, "Purchase queries remain usable without a send-only weight/category requirement")
        print("PASS: \(checks) production store request, confirmed submit, crash/restart and unknown-result checks; no network/phone/real orders")
    }
}
