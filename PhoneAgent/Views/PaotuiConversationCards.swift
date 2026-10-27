import SwiftUI

struct PaotuiConversationCards: View {
    let card: PaotuiChatCard
    let presentation: () -> PaotuiCardPresentation
    let onSelect: (PaotuiChatSelection) -> Void
    private let allowsOrderReview: Bool
    init(card: PaotuiChatCard, active: Bool, allowsOrderReview: Bool = true,
         onSelect: @escaping (PaotuiChatSelection) -> Void) {
        self.init(card: card, presentation: {
            .init(isCurrent: active, allowedActions: active ? [.choose, .quote, .review, .confirm, .edit, .more] : [])
        }, allowsOrderReview: allowsOrderReview, onSelect: onSelect)
    }
    init(card: PaotuiChatCard, presentation: @escaping () -> PaotuiCardPresentation, allowsOrderReview: Bool = true,
         onSelect: @escaping (PaotuiChatSelection) -> Void) {
        self.card = card; self.presentation = presentation; self.allowsOrderReview = allowsOrderReview; self.onSelect = onSelect
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(expired: card.expired(at: context.date), presentation: presentation())
        }
    }
    private func content(expired: Bool, presentation: PaotuiCardPresentation) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !card.goods.isEmpty {
                Label(card.goods, systemImage: card.service.contains("取送") ? "shippingbox" : "bag")
                    .font(.headline).accessibilityIdentifier("paotui.chat.goods")
            }
            if !card.purchaseAddress.isEmpty { row(card.service.contains("取送") ? "取件" : "购买", card.purchaseAddress) }
            if let contact = card.senderContact, !contact.isEmpty { row("取件人", contact) }
            if !card.recipientAddress.isEmpty { row("送达", card.recipientAddress) }
            if let contact = card.recipientContact, !contact.isEmpty { row("收件人", contact) }
            if let weight = card.itemWeight { row("重量", weight.formatted() + " 公斤 · " + (card.itemCategory ?? "")) }
            if let remark = card.remark, !remark.isEmpty { row("备注", remark) }
            if ["request", "quotes", "confirm", "receipt"].contains(card.kind) {
                VStack(alignment: .leading, spacing: 10) {
                    row("商品费", card.goodsPriceDisplayText ?? "待确认")
                    row("跑腿费", card.deliveryFeeDisplayText ?? "待查询")
                    Divider()
                    row("总价", card.totalDisplayText ?? (card.goodsPriceDisplayText == nil ? "待商品价格确认" : "待跑腿费用确认"))
                    if card.goodsPriceDisplayText == nil { Text(card.goodsPriceNote).font(.caption).foregroundStyle(.secondary) }
                }.accessibilityIdentifier("paotui.chat.prices")
                if !card.distance.isEmpty { row("距离", card.distance) }
                if !card.estimate.isEmpty { Text(card.estimate).font(.footnote).foregroundStyle(.secondary) }
            }
            ForEach(card.options) { option in
                Button { onSelect(.init(action: .choose, value: option.id)) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(option.title).font(.subheadline.weight(.medium))
                            if !option.detail.isEmpty { Text(option.detail).font(.caption).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.padding(12).frame(minHeight: 48).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).disabled(!presentation.allows(.choose) || expired).accessibilityIdentifier("paotui.chat.option." + option.id)
            }
            if ["addresses", "senderAddresses"].contains(card.kind), card.hasMoreAddresses != false {
                Button("更多地址／换个地址") { onSelect(.init(action: .more)) }.disabled(!presentation.allows(.more))
                    .accessibilityIdentifier("paotui.chat.moreAddresses")
            }
            if card.kind == "request" {
                Button("信息无误，查询费用") { onSelect(.init(action: .quote)) }
                    .buttonStyle(AgentButtonStyle()).disabled(!presentation.allows(.quote)).accessibilityIdentifier("paotui.chat.quote")
            }
            if card.kind == "confirm" {
                Text(card.inquiryOnly == true ? "本次只询价。需要下单时，请先在对话里告诉我。" : "确认后会创建真实跑腿订单。支付由你在美团完成。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("确认信息并创建订单") { onSelect(.init(action: .confirm)) }
                    .buttonStyle(AgentButtonStyle()).disabled(!presentation.canCreateOrder || expired || !card.canCreateOrder || card.inquiryOnly == true).accessibilityIdentifier("paotui.chat.confirm")
            }
            if ["quotes", "confirm"].contains(card.kind) {
                Text(expired ? "报价已过期，请重新查询。" : "报价 5 分钟内有效，实际支付金额以美团为准。")
                    .font(.caption).foregroundStyle(expired ? Color.orange : Color.secondary)
                Button("重新查询费用") { onSelect(.init(action: .quote)) }.disabled(!presentation.allows(.quote))
                    .accessibilityIdentifier("paotui.chat.refreshQuote")
            }
            if ["request", "quotes", "confirm"].contains(card.kind) {
                Button("修改商品、门店或地址") { onSelect(.init(action: .edit)) }.disabled(!presentation.allows(.edit))
                    .accessibilityIdentifier("paotui.chat.edit")
            }
            if !card.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Text(card.note).font(.caption).foregroundStyle(.secondary) }
            if let raw = card.orderURL, let url = MeituanPaotuiClient.officialURL(raw) {
                Link(url.path == "/" ? "去美团核对订单" : "在美团查看订单／完成支付", destination: url).frame(minHeight: 44)
                    .accessibilityIdentifier("paotui.chat.openOrder")
            } else if ["quotes", "confirm"].contains(card.kind) {
                Link("打开美团", destination: URL(string: "https://i.meituan.com/")!).font(.footnote)
            }
            if allowsOrderReview { PaotuiOrderReviewControl() }
            if !presentation.isCurrent { Text("此卡片仅供查看，请在当前对话继续或重新询价。").font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(16).background(AgentPalette.surface, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(.footnote).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            Text(value).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Business recovery is outside the card projection so visual fixtures never
/// gain access to the live order journal or its human-review actions.
private struct PaotuiOrderReviewControl: View {
    @ObservedObject private var store = MeituanPaotuiStore.shared
    @State private var showsOrderReview = false
    var body: some View {
        Group {
            if store.hasUnresolvedSubmission {
                Button("核验待确认订单") { showsOrderReview = true }
                    .disabled(store.busy)
                    .accessibilityIdentifier("paotui.chat.reviewPending")
            }
        }.sheet(isPresented: $showsOrderReview) { PaotuiOrderReviewSheet() }
    }
}
