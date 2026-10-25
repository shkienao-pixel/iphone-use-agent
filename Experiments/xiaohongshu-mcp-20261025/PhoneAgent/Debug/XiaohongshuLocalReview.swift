#if DEBUG
import SwiftUI
import WebKit

/// Exercises the real iOS browser, JS resource, MCP host, store and cards using
/// synthetic local HTML and a nonpersistent website store. No account/network.
struct XiaohongshuLocalReview: View {
    @MainActor final class PageState { var changedAccount = false }
    @StateObject private var host: XiaohongshuLocalMCPHost
    @StateObject private var connection: XiaohongshuMCPStore
    @State private var result = "尚未运行。示例数据，不代表真实账号或网站验收。"
    @State private var card: XHSConversationCard?
    @State private var working = false
    @Environment(\.scenePhase) private var phase
    @State private var state: PageState
    @State private var flow: XiaohongshuMCPConversation
    @State private var conversationID = UUID()

    init() {
        let connection = XiaohongshuMCPStore(defaults: UserDefaults(suiteName: "xhs-local-review-" + UUID().uuidString)!)
        let state = PageState()
        let host = XiaohongshuLocalMCPHost(websiteStore: .nonPersistent(), connection: connection) { web, url in
            let id = "0123456789abcdef01234567"
            let user: [String: Any] = ["userInfo": ["value": ["userId": state.changedAccount ? "ffffffffffffffffffffffff" : id, "nickname": "本机示例账号", "guest": false]]]
            let note: [String: Any] = ["noteId": id, "title": "手机网页笔记（示例）", "desc": "这段正文来自本机 WKWebView 中的示例页面。", "user": ["nickname": "示例作者"]]
            let page: [String: Any] = ["user": user,
                "search": ["feeds": ["value": [["id": id, "modelType": "note", "xsecToken": "PRIVATE-LOCAL-FIXTURE-REF", "noteCard": ["displayTitle": "手机网页笔记（示例）", "user": ["nickname": "示例作者"]]]]]],
                "note": ["noteDetailMap": [id: ["note": note, "comments": ["list": [["id": "local-comment", "content": "本机示例评论", "userInfo": ["nickname": "示例读者"], "subComments": [["id": "local-reply", "content": "本机示例回复", "userInfo": ["nickname": "示例作者"]]]]]]]]]]
            let json = String(decoding: try! JSONSerialization.data(withJSONObject: page), as: UTF8.self)
            web.loadHTMLString("<html><meta name='viewport' content='width=device-width'><body><h2>本机网页验证示例</h2><p>没有连接真实网站或账号。</p><script>window.__INITIAL_STATE__=\(json)</script></body></html>", baseURL: url)
        }
        _state = State(initialValue: state); _flow = State(initialValue: XiaohongshuMCPConversation(store: connection))
        _host = StateObject(wrappedValue: host); _connection = StateObject(wrappedValue: connection)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("手机本地 MCP · 原生链路验证").font(.headline)
                Text("使用本机示例网页，不代表真实账号搜索。").font(.caption)
                Text(result).accessibilityIdentifier("xhs.local.fixture.result")
                Button("运行本机读取验证") { Task { await verify() } }
                    .disabled(working).accessibilityIdentifier("xhs.local.fixture.run")
                Button("验证任务停止") {
                    host.openLogin(); host.sceneActive(false)
                    result = host.webView == nil && !host.presented && !host.busy ? "任务停止验证通过：本机页面已释放。" : "任务停止验证失败。"
                }.disabled(working).accessibilityIdentifier("xhs.local.fixture.stop")
                Button("验证账号切换拦截") { Task { await verifyChangedAccount() } }
                    .disabled(working || card == nil).accessibilityIdentifier("xhs.local.fixture.account")
                if let card {
                    XiaohongshuConversationCards(card: card, active: flow.isCurrent(card) && !working) { query in
                        Task {
                            working = true; defer { working = false }
                            do { self.card = try await flow.select(card, query: query).card }
                            catch { result = "示例读取未完成。" }
                        }
                    }
                }
            }.padding()
        }
        .task { host.install() }
        .sheet(isPresented: Binding(get: { host.presented }, set: { if !$0 { host.stop() } })) {
            XiaohongshuLocalBrowserView(host: host, connection: connection)
        }
        .onChange(of: phase) { _, value in host.sceneActive(value != .background) }
    }
    private func verify() async {
        working = true; defer { working = false }; state.changedAccount = false
        do {
            let search = try await flow.run(.init(action: .search, keyword: "咖啡"), conversationID: conversationID)
            guard let searchCard = search.card, searchCard.notes.first?.title == "手机网页笔记（示例）" else { throw AgentError.message("示例搜索卡片未返回。") }
            let detail = try await flow.select(searchCard, query: .init(action: .comments, noteID: "0123456789abcdef01234567"))
            guard detail.card?.comments.count == 2, detail.card?.notes.first?.body.contains("WKWebView") == true else { throw AgentError.message("示例正文或评论未返回。") }
            guard host.webView == nil, !host.busy, !host.presented else { throw AgentError.message("示例读取完成后页面未释放。") }
            card = detail.card
            result = "本机读取验证通过：网页 → MCP → 正文和评论卡片；完成后页面已释放。"
        } catch { result = "本机读取验证失败：" + error.localizedDescription }
    }
    private func verifyChangedAccount() async {
        working = true; defer { working = false; host.stop() }; state.changedAccount = true
        do {
            _ = try await flow.run(.init(action: .search, keyword: "咖啡"), conversationID: conversationID)
            result = "账号切换验证失败：未阻止读取。"
        } catch {
            result = !connection.ready ? "账号切换验证通过：已撤销旧账号结果的读取权限。" : "账号切换验证失败。"
        }
    }
}
#endif
