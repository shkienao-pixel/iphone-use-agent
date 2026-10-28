import Foundation

@main struct PurchaseCityChecks {
    static var checks = 0
    static func expect(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paotui-city-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = Backend()
        let store = MeituanPaotuiStore(connection: PaotuiFixtureRuntime.connection(),
            receiptURL: root.appendingPathComponent("orders.json"), clientFactory: backend.client)
        try store.installCredential("offline-city-fixture-key")
        var plan = "{}"
        let controller = MeituanPaotuiConversation(store: store, planner: { _, _, _ in plan })
        func respond(_ text: String, _ json: String, _ id: UUID) async throws -> PaotuiChatReply {
            plan = json
            return try await controller.respond(question: text, history: [], conversationID: id)
        }
        func choose(_ reply: PaotuiChatReply, _ value: String, _ id: UUID) async throws -> PaotuiChatReply {
            try await controller.select(reply.card!, .init(action: .choose, value: value), conversationID: id)
        }

        let buyID = UUID()
        var reply = try await respond("深圳买水", #"{"service":"buy","goods":"水","store":"Fixture Kitchen","city":"深圳","inquiryOnly":true}"#, buyID)
        reply = try await choose(reply, "address:2", buyID)
        reply = try await choose(reply, "poi:fixture-shop", buyID)
        expect(reply.card?.kind == "request" && backend.searchRequests.count == 1, "Initial production flow selects a shop once")
        let selected = store.session(for: buyID).preparation
        for json in [#"{"city":"深圳"}"#, #"{"city":null}"#, #"{"city":""}"#, #"{"city":"  "}"#, "{}"] {
            reply = try await respond("继续确认需求", json, buyID)
            let same = store.session(for: buyID).preparation
            expect(reply.card?.kind == "request" && same.city == "深圳" && same.draft.senderID == selected.draft.senderID,
                   "Same or empty city preserves the selected purchase shop in the production flow")
            expect(backend.searchRequests.count == 1, "Unchanged city does not trigger another shop search")
        }
        let oldCard = reply.card!
        reply = try await respond("购买城市改广州", #"{"city":"广州"}"#, buyID)
        let changed = store.session(for: buyID).preparation
        expect(changed.city == "广州" && changed.draft.senderID.isEmpty, "Changed city clears the old shop before advancing")
        expect(changed.draft.recipientID == selected.draft.recipientID && changed.inquiryOnly, "Changing purchase city preserves recipient and authorization scope")
        expect(reply.card?.kind == "places" && backend.searchRequests.count == 2 && backend.searchRequests.last?["city"] as? String == "广州",
               "Changed city invokes the actual production search and returns fresh choices")
        do {
            _ = try await controller.select(oldCard, .init(action: .quote), conversationID: buyID)
            preconditionFailure("Old-city request card remained actionable")
        } catch { checks += 1 }

        let sendID = UUID()
        reply = try await respond("深圳送文件", #"{"service":"send","goods":"文件","category":"document","weight":1,"city":"深圳","inquiryOnly":true}"#, sendID)
        reply = try await choose(reply, "address:2", sendID)
        reply = try await choose(reply, "address:1", sendID)
        let sendBefore = store.session(for: sendID).preparation
        let searchesBefore = backend.searchRequests.count
        reply = try await respond("城市改广州", #"{"city":"广州"}"#, sendID)
        let sendAfter = store.session(for: sendID).preparation
        expect(reply.card?.kind == "request" && sendAfter.draft.senderID == sendBefore.draft.senderID && sendAfter.draft.recipientID == sendBefore.draft.recipientID,
               "Send service retains both independently selected addresses")
        expect(backend.searchRequests.count == searchesBefore, "Send service never invokes purchase shop search")
        expect(backend.previews.isEmpty && backend.submissions.isEmpty, "Regressions use in-memory transport and make no quote or submission")
        print("PASS: \(checks) production conversation city-change, no-op and buy/send boundary checks; offline only")
    }
}
