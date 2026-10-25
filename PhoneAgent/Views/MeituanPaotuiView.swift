import SwiftUI

/// Connection management only. Business selections and order confirmations live
/// in the Sela conversation, never in a separate configuration/order form.
struct MeituanPaotuiView: View {
    var onChat: () -> Void = {}
    @ObservedObject private var store = MeituanPaotuiStore.shared
    @State private var disconnecting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("美团跑腿", systemImage: "bicycle").font(.headline)
                Spacer()
                Text(store.statusLabel).font(.caption).foregroundStyle(store.ready ? .green : .secondary)
                    .accessibilityIdentifier("paotui.connectionStatus")
            }
            Text("在 Sela 对话中描述需求，选择地址和门店，再核对费用与订单。这里仅管理账号连接。")
                .font(.subheadline).foregroundStyle(.secondary)
            if !store.configured {
                Button("连接美团跑腿") { Task { await store.startAuthorization() } }
                    .buttonStyle(AgentButtonStyle()).disabled(store.busy).accessibilityIdentifier("paotui.connect")
            } else {
                Button("回到对话描述需求", action: onChat).buttonStyle(AgentButtonStyle())
                    .accessibilityIdentifier("paotui.openConversation")
                Button("检测跑腿连接") { Task { await store.refresh() } }.disabled(store.busy)
                    .accessibilityIdentifier("paotui.refresh")
                Button("重新授权跑腿") { Task { await store.startAuthorization() } }.disabled(store.busy)
            }
            if let link = store.authorizationLink {
                Link("前往美团授权", destination: link)
                Button("我已授权，检测连接") { Task { await store.finishAuthorization() } }
                    .buttonStyle(AgentButtonStyle()).disabled(store.busy).accessibilityIdentifier("paotui.finishAuthorization")
                Button("取消本次授权", role: .cancel) { store.cancelAuthorization() }.disabled(store.busy)
            }
            if store.busy { ProgressView("正在连接美团…") }
            if !store.message.isEmpty { AgentNotice(text: store.message, error: store.failed) }
            if store.hasUnresolvedSubmission {
                AgentNotice(text: "上一笔跑腿提交结果仍需在美团核对。可以继续对话和询价，Sela 不会重复创建订单。", error: true)
                Link("打开美团核对已有订单", destination: store.chatOrderURL ?? URL(string: "https://i.meituan.com/")!)
            }
            if store.configured { Button("断开跑腿连接", role: .destructive) { disconnecting = true }.disabled(store.busy) }
            DisclosureGroup("旅行服务") { MeituanConnectionView().padding(.top, 16) }
        }
        .task { if store.configured && !store.ready { await store.refresh() } }
        .confirmationDialog("清除这部手机的跑腿授权？", isPresented: $disconnecting, titleVisibility: .visible) {
            Button("断开连接", role: .destructive) { try? store.disconnect() }
        }
    }
}
