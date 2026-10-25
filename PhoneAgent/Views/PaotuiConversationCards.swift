import SwiftUI

struct PaotuiConversationCards: View {
    let card: PaotuiChatCard
    let active: Bool
    let onSelect: (PaotuiChatSelection) -> Void
    private func amount(_ number: Double) -> String { number.formatted(.number.precision(.fractionLength(0...2))) + " 元" }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(expired: card.expired(at: context.date))
        }
    }
    private func content(expired: Bool) -> some View {
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
                    row("商品费", card.goodsPrice.map(amount) ?? "待确认")
                    row("跑腿费", card.deliveryFee.map(amount) ?? "待查询")
                    Divider()
                    row("总价", card.total.map(amount) ?? (card.goodsPrice == nil ? "待商品价格确认" : "待跑腿费用确认"))
                    if card.goodsPrice == nil { Text(card.goodsPriceNote).font(.caption).foregroundStyle(.secondary) }
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
                }.buttonStyle(.plain).disabled(!active || expired).accessibilityIdentifier("paotui.chat.option." + option.id)
            }
            if ["addresses", "senderAddresses"].contains(card.kind), card.hasMoreAddresses != false {
                Button("更多地址／换个地址") { onSelect(.init(action: .more)) }.disabled(!active)
                    .accessibilityIdentifier("paotui.chat.moreAddresses")
            }
            if card.kind == "request" {
                Button("信息无误，查询费用") { onSelect(.init(action: .quote)) }
                    .buttonStyle(AgentButtonStyle()).disabled(!active).accessibilityIdentifier("paotui.chat.quote")
            }
            if card.kind == "confirm" {
                Text(card.inquiryOnly == true ? "本次只询价。需要下单时，请先在对话里告诉我。" : "确认后会创建真实跑腿订单。支付由你在美团完成。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("确认信息并创建订单") { onSelect(.init(action: .confirm)) }
                    .buttonStyle(AgentButtonStyle()).disabled(!active || expired || !card.canCreateOrder || card.inquiryOnly == true).accessibilityIdentifier("paotui.chat.confirm")
            }
            if ["quotes", "confirm"].contains(card.kind) {
                Text(expired ? "报价已过期，请重新查询。" : "报价 5 分钟内有效，实际支付金额以美团为准。")
                    .font(.caption).foregroundStyle(expired ? Color.orange : Color.secondary)
                Button("重新查询费用") { onSelect(.init(action: .quote)) }.disabled(!active)
                    .accessibilityIdentifier("paotui.chat.refreshQuote")
            }
            if ["request", "quotes", "confirm"].contains(card.kind) {
                Button("修改商品、门店或地址") { onSelect(.init(action: .edit)) }.disabled(!active)
                    .accessibilityIdentifier("paotui.chat.edit")
            }
            if !card.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Text(card.note).font(.caption).foregroundStyle(.secondary) }
            if let raw = card.orderURL, let url = MeituanPaotuiClient.officialURL(raw) {
                Link(url.path == "/" ? "去美团核对订单" : "在美团查看订单／完成支付", destination: url).frame(minHeight: 44)
                    .accessibilityIdentifier("paotui.chat.openOrder")
            } else if ["quotes", "confirm"].contains(card.kind) {
                Link("打开美团", destination: URL(string: "https://i.meituan.com/")!).font(.footnote)
            }
            if !active { Text("此卡片仅供查看，请在当前对话继续或重新询价。").font(.caption2).foregroundStyle(.secondary) }
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
