import Foundation

/// Interpretation is a proposal tied to one captured user turn. It has no
/// price, address ID, quote token or execution command fields.
@MainActor struct PaotuiInterpretationPatch {
    enum Change<Value> { case unchanged, set(Value), clear }
    enum Intent { case continuing, new, cancel, ordinaryFood }
    struct Source {
        let ticket: PaotuiSession.Ticket
        let requestID: UUID
        let directUserText: String
        init(ticket: PaotuiSession.Ticket, requestID: UUID, directUserText: String) {
            self.ticket = ticket; self.requestID = requestID; self.directUserText = directUserText
        }
    }
    let source: Source
    let intent: Intent
    let service: Change<PaotuiService>
    let goods: Change<String>
    let store: Change<String>
    let city: Change<String>
    let recipientKeyword: Change<String>
    let senderKeyword: Change<String>
    let nearby: Change<Bool>
    let remark: Change<String>
    let weight: Change<Double>
    let category: Change<PaotuiCategory>
    let inquiryOnly: Change<Bool>
    let clarification: String?

    init(plan: MeituanPaotuiConversation.Plan, source: Source) {
        self.source = source
        intent = switch plan.intent { case "new": .new; case "cancel": .cancel; case "ordinary_food": .ordinaryFood; default: .continuing }
        func value<T>(_ value: T?) -> Change<T> { value.map(Change.set) ?? .unchanged }
        func text(_ value: String?, clear: Bool = false) -> Change<String> {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .set(value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return clear ? .clear : .unchanged
        }
        service = value(plan.service); goods = text(plan.goods, clear: plan.edit == .goods)
        store = text(plan.store, clear: plan.edit == .store); city = text(plan.city)
        recipientKeyword = text(plan.recipient, clear: plan.edit == .recipient)
        senderKeyword = text(plan.sender, clear: plan.edit == .sender)
        nearby = value(plan.nearby); remark = text(plan.remark, clear: plan.edit == .remark)
        weight = plan.weight.map(Change.set) ?? (plan.edit == .goods ? .clear : .unchanged)
        category = plan.category.map(Change.set) ?? (plan.edit == .goods ? .clear : .unchanged)
        // A model reading memory, attachments, or quoted text cannot relax an
        // inquiry-only restriction. A new direct user event must say so itself.
        if plan.inquiryOnly == true { inquiryOnly = .set(true) }
        else if plan.inquiryOnly == false && Self.explicitOrderIntent(source.directUserText) { inquiryOnly = .set(false) }
        else { inquiryOnly = .unchanged }
        clarification = plan.clarification
    }

    static func explicitOrderIntent(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let expression = #"^(?:现在|这次|本次)?(?:我)?(?:要下单|想下单|决定下单|改为下单|可以下单|下单吧|下单)(?:了|吧)?[。！!，,\s]*$"#
        return text.range(of: expression, options: .regularExpression) != nil
    }

    func applying(to previous: PaotuiSession.Preparation, expected: PaotuiSession.Ticket) throws -> PaotuiSession.Preparation {
        guard source.ticket == expected else { throw PaotuiSession.SessionError.stale }
        var result = previous
        if intent == .new || intent == .ordinaryFood { result = .init(); result.inquiryOnly = previous.inquiryOnly }
        if case .set(let only) = inquiryOnly { result.inquiryOnly = only }
        if case .set(let newService) = service {
            if result.draft.service != newService {
                result.draft.senderID = ""; result.draft.nearby = false
                result.draft.weight = nil; result.draft.category = nil
            }
            result.draft.service = newService
        }
        func change<T>(_ patch: Change<T>, _ current: inout T, empty: T) {
            switch patch { case .unchanged: break; case .set(let value): current = value; case .clear: current = empty }
        }
        change(goods, &result.draft.goods, empty: "")
        switch store {
        case .unchanged: break
        case .clear: result.keyword = ""; result.draft.senderID = ""; result.draft.nearby = false
        case .set(let keyword):
            if case .set(.send) = service { throw AgentError.message("请补充取件地址，在美团保存完整联系人信息后选择。") }
            if result.draft.service != .buy { result.draft.weight = nil; result.draft.category = nil }
            result.keyword = keyword; result.draft.senderID = ""; result.draft.nearby = false; result.draft.service = .buy
        }
        change(city, &result.city, empty: "")
        switch recipientKeyword {
        case .unchanged: break
        case .clear, .set:
            result.draft.recipientID = ""; result.addressOffset = 0
            if result.draft.service == .buy { result.draft.senderID = "" }
            change(recipientKeyword, &result.recipientKeyword, empty: "")
        }
        switch senderKeyword {
        case .unchanged: break
        case .clear, .set:
            result.draft.senderID = ""; result.addressOffset = 0
            change(senderKeyword, &result.senderKeyword, empty: "")
        }
        if case .set(let nearby) = nearby { result.draft.nearby = nearby; result.draft.senderID = "" }
        change(remark, &result.draft.remark, empty: "")
        switch weight { case .unchanged: break; case .clear: result.draft.weight = nil; case .set(let value): result.draft.weight = value }
        switch category { case .unchanged: break; case .clear: result.draft.category = nil; case .set(let value): result.draft.category = value }
        return result
    }
}
