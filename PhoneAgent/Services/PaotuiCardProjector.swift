import Foundation

/// Field assembly is pure. A projected card is display data until the actual
/// live Session accepts the final complete value with Session.offer.
enum PaotuiCardProjector {
    struct Output {
        let text: String
        let kind: String
        var options: [PaotuiChatOption] = []
        var quote: PaotuiSessionSummary.Quote? = nil
        var hasMoreAddresses: Bool? = nil
        var extraNote = ""
        var orderURL: URL? = nil
        var noteOverride: String? = nil
    }

    static func project(_ summary: PaotuiSessionSummary, output: Output) -> PaotuiChatCard {
        let draft = summary.draft
        var card = PaotuiChatCard(conversationID: summary.conversationID, kind: output.kind,
                                  title: PaotuiAddress.redactingPhones(output.text), options: output.options.map {
                                      PaotuiChatOption(id: $0.id, title: PaotuiAddress.redactingPhones($0.title),
                                          detail: PaotuiAddress.redactingPhones($0.detail))
                                  })
        card.goods = draft.goods; card.service = draft.service == "buy" ? "帮买" : draft.service == "send" ? "帮取送" : ""
        card.purchaseAddress = draft.nearby ? "骑手就近购买" : summary.sender?.fullAddress ?? ""
        card.recipientAddress = summary.recipient?.fullAddress ?? ""
        card.recipientContact = summary.recipient?.contact
        if draft.service == "send" { card.senderContact = summary.sender?.contact }
        card.inquiryOnly = summary.inquiryOnly; card.remark = draft.remark
        if draft.service == "send" {
            card.itemWeight = draft.weight; card.itemCategory = draft.category
            card.goodsPrice = 0; card.goodsPriceMinorUnits = 0; card.currency = "CNY"
            card.goodsPriceNote = "帮取送不含代购商品"
        }
        if let quote = output.quote {
            card.purchaseAddress = quote.senderTitle; card.recipientAddress = quote.recipientTitle
            card.recipientContact = quote.recipientContact
            if quote.isSend { card.senderContact = quote.senderContact }
            card.quoteID = quote.id; card.deliveryFee = quote.fee; card.estimate = quote.estimate
            card.currency = quote.currency; card.deliveryFeeMinorUnits = quote.deliveryFeeMinorUnits
            card.deliveryFeeText = quote.feeText
            card.distance = quote.distance; card.service = quote.serviceTitle; card.note = quote.goodsPaymentNote
            if quote.isSend {
                card.goodsPrice = 0; card.goodsPriceMinorUnits = 0
                card.goodsPriceNote = "帮取送不含代购商品"
            }
            card.validUntil = quote.validUntil
            card.canCreateOrder = quote.canCreateOrder && !summary.inquiryOnly
        }
        if summary.inquiryOnly { card.note += "\n本次只询价，不创建订单。如需下单，请在对话里说明。" }
        if summary.hasUnresolvedSubmission { card.note += "\n上一笔跑腿提交结果尚待核验。本次可询价，暂不能重复创建订单。" }
        card.hasMoreAddresses = output.hasMoreAddresses
        card.note += PaotuiAddress.redactingPhones(output.extraNote)
        card.orderURL = output.orderURL?.absoluteString
        if let noteOverride = output.noteOverride { card.note = PaotuiAddress.redactingPhones(noteOverride) }
        return card
    }
}
