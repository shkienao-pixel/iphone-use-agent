#if DEBUG
import SwiftUI

/// Visual-only fixture for the actual native cards. No model, account, cookie
/// or network activity is started by these preview actions.
struct XiaohongshuMCPReview: View {
    @State private var comments = false
    private let id = UUID()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Sela · 小红书卡片预览").font(.headline)
                Text("示例数据，不代表真实搜索或账号登录。").font(.caption).foregroundStyle(.secondary)
                XiaohongshuConversationCards(card: .init(conversationID: id,
                    title: comments ? "本次读取的评论" : "搜索结果", kind: comments ? "comments" : "search",
                    notes: [.init(id: "0123456789abcdef01234567", title: "深圳咖啡店的一天（示例）", author: "示例作者", body: comments ? "这里是笔记正文示例。" : "")],
                    comments: comments ? [.init(id: "fixture-comment", author: "示例读者", text: "这家店周末人多吗？", reply: false), .init(id: "fixture-reply", author: "示例作者", text: "可以提前看看营业时间。", reply: true)] : [],
                    coverage: comments ? "示例：读取 1 条一级评论和 1 条回复，仅代表已加载范围。" : "示例：展示 1 条结果，未继续翻页。"), active: true) { _ in comments = true }
            }.padding()
        }.background(AgentPalette.background)
    }
}
#endif
