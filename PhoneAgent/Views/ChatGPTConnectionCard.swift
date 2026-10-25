import SwiftUI

/// The same row, icon size and status treatment as other App connections.
struct ChatGPTConnectionCard: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @ObservedObject private var auth = ChatGPTPlanAuthorization.shared
    let identifier: String
    let onConfiguration: (SettingsPage) -> Void
    private var authorized: Bool { auth.accounts.first { $0.id == auth.activeID }?.sharing == true }
    private var connected: Bool { model.settings.usesChatGPTPlan && model.modelReady && authorized }
    private var status: String { connected ? "已连接" : (authorized ? "已授权" : "待登录") }
    var body: some View {
        ConnectionRow("ChatGPT", detail: connected ? model.settings.model : "使用 Work / Codex 计划与可用额度",
            icon: "sparkles", brandAsset: "Brand-chatgpt", status: status, ready: connected,
            identifier: identifier, action: open)
            .onAppear { auth.reload() }
    }
    private func open() {
        if !model.settings.usesChatGPTPlan {
            guard !model.engine.running, !model.engine.releasing, !model.voicePending else {
                model.notice = "请先暂停当前任务，再更换模型连接"; return
            }
            var settings = model.settings
            settings.modelAuthentication = "chatgpt_plan"
            settings.endpoint = ChatGPTPlanProtocol.endpoint
            settings.providerName = "ChatGPT 计划"
            settings.jsonMode = true; settings.legacyTokenLimit = false
            model.settings = settings
        }
        onConfiguration(.model)
    }
}
