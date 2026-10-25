import SwiftUI

struct ChatGPTPlanSettingsView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @ObservedObject private var auth = ChatGPTPlanAuthorization.shared
    private var selected: ChatGPTPlanAuthorization.Account? { auth.accounts.first { $0.id == auth.activeID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("使用你现有的 Work / Codex 计划和可用额度。登录时选择账户，并允许 Sela 使用 ChatGPT 计划。")
                .font(.subheadline).foregroundStyle(AgentPalette.secondaryText)
            if !auth.accounts.isEmpty {
                Menu {
                    ForEach(auth.accounts) { account in Button(account.label) { auth.select(account.id); model.objectWillChange.send() } }
                } label: {
                    Label(selected?.label ?? "选择已保存账户", systemImage: "person.crop.circle")
                }.disabled(auth.connecting)
            }
            if selected?.sharing == true {
                Label("正在使用 ChatGPT 计划", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if !auth.models.isEmpty {
                    Picker("模型", selection: $model.settings.model) {
                        if !auth.models.contains(where: { $0.id == model.settings.model }) { Text(model.settings.model + "（当前不可用）").tag(model.settings.model) }
                        ForEach(auth.models) { item in Text(item.name).tag(item.id) }
                    }
                } else { Text("模型：" + model.settings.model).font(.subheadline) }
                Button("刷新可用模型") { Task { await auth.loadModels() } }.disabled(auth.connecting)
            }
            if auth.connecting {
                ProgressView("正在连接 ChatGPT…")
                Button("取消登录", role: .cancel) { auth.cancel() }
            } else {
                Button("Continue with ChatGPT") { Task { await auth.signIn(); model.objectWillChange.send() } }
                    .buttonStyle(AgentButtonStyle()).accessibilityIdentifier("chatgpt.signin")
                if !auth.accounts.isEmpty {
                    Button("添加 ChatGPT 账户") { Task { await auth.signIn(newAccount: true); model.objectWillChange.send() } }
                    if selected != nil { Button("退出此连接") { Task { await auth.signOut(); model.objectWillChange.send() } } }
                }
            }
            Link("管理 ChatGPT 用量", destination: URL(string: "https://chatgpt.com/settings/usage")!)
            Text("此连接用于文字与图片请求。可在 ChatGPT 设置中管理 Sela 的限额或断开授权。")
                .font(.caption).foregroundStyle(AgentPalette.secondaryText)
            if !auth.message.isEmpty { AgentNotice(text: auth.message) }
        }
        .onAppear { auth.reload(); if selected?.sharing == true { Task { await auth.loadModels() } } }
    }
}
