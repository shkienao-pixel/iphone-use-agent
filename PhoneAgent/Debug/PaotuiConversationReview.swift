#if DEBUG
import SwiftUI

/// Read-only visual fixture. It never loads credentials, calls a model/service,
/// or uses the real conversational controller's order-confirmation handler.
struct PaotuiConversationReview: View {
    @State private var stage: Int
    private let conversationID = UUID()
    init() {
        let args = ProcessInfo.processInfo.arguments
        let value = args.firstIndex(of: "--paotui-preview-stage").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil } ?? 0
        _stage = State(initialValue: max(0, min(3, value)))
    }
    private let titles = ["送到哪里？点击地址，也可以直接说地址关键词。", "先核对这些信息，正确后我再向美团查询实际跑腿费。", "这是美团返回的跑腿方案。商品费尚未确定，因此完整总价仍待确认。", "请在对话中最后确认订单信息。"]
    private var card: PaotuiChatCard {
        var card = PaotuiChatCard(conversationID: conversationID, kind: ["addresses", "request", "quotes", "confirm"][stage], title: titles[stage])
        card.goods = "超模厨房的鸡肉饭一份"; card.service = "帮买"
        card.inquiryOnly = true; card.remark = "少盐，不要辣"
        if stage == 0 {
            card.options = [.init(id: "fixture-home", title: "御成府（示例地址）", detail: "收货人 · 138****0000"),
                .init(id: "fixture-salon", title: "洛芙蒂美甲美睫（海岸城店）", detail: "海岸城商圈 · 138****0000")]
            card.hasMoreAddresses = true
        } else {
            card.purchaseAddress = "Super Model 超模厨房（深圳南山店）"
            card.recipientAddress = "洛芙蒂美甲美睫（海岸城店）"
            card.recipientContact = "收货人 · 138****0000"
        }
        if stage >= 2 {
            card.deliveryFee = 18; card.distance = "示例：1.3 公里"; card.estimate = "示例：预计 30 分钟送达"
            card.validUntil = Date().addingTimeInterval(300)
            card.note = "示例数据，仅供排版检查。商品价由骑手到店核实。"
        }
        if stage == 2 { card.options = [.init(id: "fixture-quote", title: "帮买 · 18 元", detail: "示例跑腿方案，查看确认信息")] }
        return card
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sela").font(.headline)
                Spacer()
                Text("界面预览 · 示例数据").font(.caption).foregroundStyle(.secondary)
            }.padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Spacer(minLength: 36)
                        Text("帮我买一份超模厨房的鸡肉饭，先只询价。")
                            .padding(14).background(AgentPalette.surface, in: RoundedRectangle(cornerRadius: 18))
                    }
                    Text(titles[stage]).font(.body)
                    PaotuiConversationCards(card: card, active: true, allowsOrderReview: false) { selection in
                        switch selection.action {
                        case .choose, .quote: stage = min(3, stage + 1)
                        case .edit, .more: stage = 0
                        default: break
                        }
                    }
                }.padding()
            }
            Divider()
            HStack {
                Button("上一步") { stage = max(0, stage - 1) }.disabled(stage == 0)
                Spacer()
                Text(["选地址", "核对需求", "费用明细", "最终确认"][stage]).font(.caption)
                Spacer()
                Button("下一步") { stage = min(3, stage + 1) }.disabled(stage == 3)
            }.padding()
        }.background(AgentPalette.background)
    }
}
#endif
