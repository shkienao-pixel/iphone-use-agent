import SwiftUI
import WebKit

struct XiaohongshuMCPConnectionView: View {
    var onChat: () -> Void = {}
    @ObservedObject private var store = XiaohongshuMCPStore.shared
    @ObservedObject private var local = XiaohongshuLocalMCPHost.shared
    @State private var endpoint = ""
    @State private var token = ""
    @State private var error = ""
    var body: some View {
        ConnectionPage {
            Label("小红书 MCP", systemImage: "book.closed").font(.title2.weight(.semibold))
            Text("在 Sela 对话中搜索笔记、读取正文和评论。选择手机本地运行时，任务会在这部手机的网页中执行。")
                .font(.subheadline).foregroundStyle(.secondary)
            Picker("运行位置", selection: Binding(get: { store.mode }, set: { store.selectMode($0) })) {
                Text("这部手机").tag(XiaohongshuMCPStore.Mode.local)
                Text("外部 MCP").tag(XiaohongshuMCPStore.Mode.remote)
            }.pickerStyle(.segmented).disabled(store.busy || local.busy).accessibilityIdentifier("xhs.mode")
            Text(store.statusLabel).font(.subheadline).accessibilityIdentifier("xhs.connectionStatus")
            if store.mode == .local {
                Text("手机本地 · 验证版").font(.headline)
                Text("不用填写服务器地址。在 Sela 内的小红书网页登录自己的账号；任务开始时打开网页，完成后释放页面。请保持 Sela 在前台。")
                    .font(.subheadline).foregroundStyle(.secondary)
                if !local.accountName.isEmpty { Text("当前网页账号：" + local.accountName).font(.subheadline) }
                Button("在手机内登录小红书") { local.openLogin() }
                    .buttonStyle(AgentButtonStyle()).disabled(store.busy || local.busy).accessibilityIdentifier("xhs.local.login")
                Button("检查本机网页登录") { Task { await store.checkLogin() } }
                    .disabled(store.busy || local.busy).accessibilityIdentifier("xhs.local.check")
                Text("网页能否完整提供搜索、正文和评论，仍需账号实测。当前只读取内容；不会发布、点赞或发送评论。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("清除 Sela 内的网页登录", role: .destructive) { Task { await local.clearLogin() } }
                    .disabled(store.busy || local.busy).accessibilityIdentifier("xhs.local.clear")
            } else {
            TextField("HTTPS MCP 地址（以 /mcp 结尾）", text: $endpoint)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("xhs.endpoint")
                .onChange(of: endpoint) { _, _ in token = "" }
            SecureField("连接访问密钥", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("xhs.token")
            Text("使用兼容 xpzouying/xiaohongshu-mcp 的自建服务。这里填写服务的访问密钥；小红书账号在扫码页面登录。")
                .font(.caption).foregroundStyle(.secondary)
            Button("保存连接") {
                do { try store.save(endpoint: endpoint, token: token); token = ""; error = "" }
                catch { self.error = error.localizedDescription }
            }.buttonStyle(AgentButtonStyle()).disabled(store.busy).accessibilityIdentifier("xhs.save")
            if store.configured {
                Button("检查账号登录") { Task { await store.checkLogin() } }.disabled(store.busy).accessibilityIdentifier("xhs.checkLogin")
                Button("获取扫码登录二维码") { Task { await store.loginQRCode() } }.disabled(store.busy).accessibilityIdentifier("xhs.loginQRCode")
            }
            if let data = store.qrImage, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 280)
                    .accessibilityLabel("小红书账号登录二维码")
            }
            }
            if store.busy { ProgressView(store.mode == .local ? "正在检查本机网页…" : "正在连接 MCP 服务…") }
            if !store.message.isEmpty { Text(store.message).font(.footnote).accessibilityIdentifier("xhs.connectionMessage") }
            if !error.isEmpty { Text(error).font(.footnote).foregroundStyle(.red) }
            Button("回到对话搜索笔记", action: onChat).buttonStyle(AgentButtonStyle())
                .accessibilityIdentifier("xhs.openConversation")
            Text("当前连接开放搜索和读取。评论显示实际加载条数；图片内文字与视频口播需要另外识别。")
                .font(.caption).foregroundStyle(.secondary)
            if store.mode == .remote && store.configured {
                Button("断开本机连接", role: .destructive) { do { try store.disconnect(); endpoint = ""; token = "" } catch { self.error = error.localizedDescription } }
                    .disabled(store.busy)
            }
            Link("查看 MCP 项目说明", destination: URL(string: "https://github.com/xpzouying/xiaohongshu-mcp")!)
        }.task { local.install(); endpoint = store.endpoint }
    }
}

struct XiaohongshuConversationCards: View {
    let card: XHSConversationCard
    let active: Bool
    let onRead: (XHSReadQuery) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("小红书 · " + card.title, systemImage: "book.closed").font(.headline)
            ForEach(Array(card.notes.enumerated()), id: \.element.id) { index, note in
                VStack(alignment: .leading, spacing: 10) {
                    Text(card.kind == "search" ? "\(index + 1). " + note.title : note.title).font(.subheadline.weight(.semibold))
                    if !note.author.isEmpty { Text(note.author).font(.caption).foregroundStyle(.secondary) }
                    if !note.body.isEmpty && card.kind != "comments" { Text(note.body).font(.body).textSelection(.enabled) }
                    HStack {
                        Button("读取正文") { onRead(.init(action: .detail, noteID: note.id)) }
                            .disabled(!active).accessibilityIdentifier("xhs.read." + note.id)
                        Button("读取评论") { onRead(.init(action: .comments, noteID: note.id)) }
                            .disabled(!active).accessibilityIdentifier("xhs.comments." + note.id)
                        Spacer()
                        Link("查看原文", destination: URL(string: note.sourceURL)!)
                    }.font(.footnote).frame(minHeight: 44)
                }
                if index < card.notes.count - 1 { Divider() }
            }
            ForEach(card.comments) { comment in
                VStack(alignment: .leading, spacing: 4) {
                    Text((comment.reply ? "回复 · " : "") + comment.author).font(.caption).foregroundStyle(.secondary)
                    Text(comment.text).font(.subheadline).textSelection(.enabled)
                }.padding(.leading, comment.reply ? 16 : 0)
            }
            if !card.coverage.isEmpty { Text(card.coverage).font(.caption).foregroundStyle(.secondary) }
            Text("读取于 " + card.observedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
            if !active { Text("历史结果仅供查看，请在当前对话重新搜索或读取。 ").font(.caption2).foregroundStyle(.secondary) }
        }.padding(16).background(AgentPalette.surface, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct XiaohongshuLocalBrowserView: View {
    @ObservedObject var host: XiaohongshuLocalMCPHost
    @ObservedObject var connection: XiaohongshuMCPStore = .shared
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    if host.busy { ProgressView() }
                    Text(host.message).font(.subheadline).accessibilityIdentifier("xhs.local.message")
                }.padding(.horizontal)
                if let web = host.webView { XiaohongshuLocalWebView(webView: web).id(ObjectIdentifier(web)).accessibilityIdentifier("xhs.local.web") }
                else { ContentUnavailableView("本机网页已停止", systemImage: "globe") }
                Text("这是 Sela 内的小红书网页，请保持 Sela 在前台。关闭页面会停止当前读取。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
            .navigationTitle("小红书 · 本机网页").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { host.stop() }.accessibilityIdentifier("xhs.local.close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认登录") { Task { await connection.checkLogin() } }
                        .disabled(host.busy || connection.busy || connection.mode != .local).accessibilityIdentifier("xhs.local.confirm")
                }
            }
        }
    }
}

private struct XiaohongshuLocalWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
