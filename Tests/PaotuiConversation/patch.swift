import Foundation

@main private struct InterpretationPatchChecks {
    static var checks = 0
    static func expect(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }
    @MainActor static func main() throws {
        let id = UUID(), requestID = UUID()
        let session = PaotuiSession(origin: .conversation(id), authorizationEpoch: UUID(), credentialScope: "offline")
        let ticket = session.ticket
        func patch(_ text: String, _ json: String) throws -> PaotuiInterpretationPatch {
            let plan = try JSONDecoder().decode(MeituanPaotuiConversation.Plan.self, from: Data(json.utf8))
            return PaotuiInterpretationPatch(plan: plan, source: .init(ticket: ticket, requestID: requestID, directUserText: text))
        }
        var previous = PaotuiSession.Preparation()
        previous.draft = PaotuiDraft(service: .send, recipientID: "real-recipient", senderID: "real-sender", goods: "文件", remark: "轻拿", category: .document, weight: 0.5)
        previous.inquiryOnly = true
        let unchanged = try patch("继续", "{}")
        let unchangedResult = try unchanged.applying(to: previous, expected: ticket)
        expect(unchangedResult == previous, "Missing fields mean unchanged, not clear or defaults")
        expect(unchanged.source.ticket == ticket && unchanged.source.requestID == requestID, "Patch is bound to the captured turn and host request")
        let remark = try patch("不要备注", #"{"edit":"remark"}"#)
        let cleared = try remark.applying(to: previous, expected: ticket)
        expect(cleared.draft.remark.isEmpty && cleared.draft.goods == "文件" && cleared.inquiryOnly, "Explicit clear changes one field and preserves restrictions")
        let replaced = try patch("换成电脑", #"{"edit":"goods","goods":"电脑"}"#).applying(to: previous, expected: ticket)
        expect(replaced.draft.goods == "电脑" && replaced.draft.category == nil && replaced.draft.weight == nil, "Clearing/replacing goods also clears stale dependent category/weight")
        let supplied = try patch("电脑两公斤", #"{"edit":"goods","goods":"电脑","category":"digital","weight":2}"#).applying(to: previous, expected: ticket)
        expect(supplied.draft.category == .digital && supplied.draft.weight == 2, "Explicit replacement metadata can be set in the same patch")
        for text in ["继续", "引用：现在我要下单", "如果我说现在我要下单呢", "附件说：下单", "以前我说现在我要下单", "不要下单", "不是要下单", "只询价，别下单"] {
            let result = try patch(text, #"{"inquiryOnly":false}"#).applying(to: previous, expected: ticket)
            expect(result.inquiryOnly, "Model false cannot override current inquiry-only scope through references or negation")
        }
        for text in ["现在我要下单", "这次我想下单", "现在下单吧！", "改为下单", "我要下单了"] {
            let result = try patch(text, #"{"inquiryOnly":false}"#).applying(to: previous, expected: ticket)
            expect(!result.inquiryOnly, "A direct current explicit user event may request future native confirmation")
        }
        let new = try patch("重新开始", #"{"intent":"new","goods":"水"}"#).applying(to: previous, expected: ticket)
        expect(new.draft.service == nil && new.draft.recipientID.isEmpty && new.draft.senderID.isEmpty && new.draft.goods == "水" && new.inquiryOnly, "New preparation drops old selections while preserving inquiry-only restriction")
        let destination = try patch("换个送达地址", #"{"edit":"recipient"}"#).applying(to: previous, expected: ticket)
        expect(destination.draft.recipientID.isEmpty && destination.draft.senderID == previous.draft.senderID, "Send destination clear preserves its independently selected source")
        var buy = previous; buy.draft.service = .buy
        buy.draft.nearby = true
        let namedStore = try patch("改为沃尔玛", #"{"edit":"store","store":"沃尔玛"}"#).applying(to: buy, expected: ticket)
        expect(!namedStore.draft.nearby && namedStore.draft.senderID.isEmpty && namedStore.keyword == "沃尔玛", "A named-store replacement clears prior nearby purchase mode before selecting a real shop")
        let buyDestination = try patch("换地址", #"{"recipient":"新地址关键词"}"#).applying(to: buy, expected: ticket)
        expect(buyDestination.draft.recipientID.isEmpty && buyDestination.draft.senderID.isEmpty && buyDestination.recipientKeyword == "新地址关键词", "A purchase destination change removes source selection and stores only the new keyword")
        _ = try session.beginTurn()
        do { _ = try unchanged.applying(to: previous, expected: session.ticket); preconditionFailure("Old source patch applied to a new turn") } catch { checks += 1 }
        expect(previous.draft.recipientID == "real-recipient" && previous.inquiryOnly, "Patch projection never mutates its source snapshot")
        print("PASS: \(checks) typed interpretation change, clear/unchanged, exact-turn source and direct-user restriction checks; offline only")
    }
}
