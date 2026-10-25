import SwiftUI

struct CtripSettingsView: View {
    var showsIntro = true
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.scenePhase) private var phase
    @FocusState private var keyFocused: Bool
    @State private var enabled = CtripStore.enabled
    @State private var connectionMode = CtripStore.connectionMode
    @State private var hasCredential = CtripStore.hasCredential
    @State private var keyDraft = ""
    @State private var confirmingEnable = false
    @State private var confirmingClear = false
    @State private var message = ""
    @State private var failed = false
    private var locked: Bool { model.engine.running || model.engine.releasing || model.voicePending }
    private var controlsLocked: Bool { locked }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsIntro { AgentPageIntro(title: "连接携程", subtitle: "在任务中查询机票、酒店、火车票和旅行建议。", icon: "airplane") }
            Link(destination: ExternalAppService.ctrip.documentationURL) {
                Label("获取携程授权码", systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.accessibilityIdentifier("apps.ctrip.getCredential")
            AgentCard {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("接入方式", selection: $connectionMode) {
                        ForEach(CtripConnectionMode.allCases) { Text($0.title).tag($0) }
                    }.onChange(of: connectionMode) { _, mode in
                        CtripStore.connectionMode = mode; enabled = false
                    }
                    Toggle("启用携程查询", isOn: Binding(get: { enabled }, set: requestEnabled))
                        .disabled(controlsLocked)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(hasCredential ? "替换授权码" : "携程授权码")
                            .font(.caption).foregroundStyle(AgentPalette.secondaryText)
                        SecureField(hasCredential ? "输入新的授权码" : "输入携程授权码", text: $keyDraft)
                            .textContentType(.password).textInputAutocapitalization(.never)
                            .autocorrectionDisabled().agentField().focused($keyFocused)
                            .accessibilityLabel("新的携程授权码")
                            .disabled(controlsLocked)
                    }
                }
            }
            Button("保存授权码", action: saveCredential)
                .buttonStyle(AgentButtonStyle())
                .disabled(controlsLocked || keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if hasCredential {
                Button("清除授权码", role: .destructive) { confirmingClear = true }
                    .frame(minHeight: 44).disabled(controlsLocked)
            }
            if locked { AgentNotice(text: "任务结束或暂停后，可调整携程设置。") }
            if !message.isEmpty { AgentNotice(text: message, error: failed) }
        }
        .confirmationDialog("开启携程查询？", isPresented: $confirmingEnable, titleVisibility: .visible) {
            Button("同意并开启") { enableAfterConsent() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("允许助手将任务中的旅行查询发送给携程，并将查询结果交给当前 AI、保存到本机任务记录。查询可能消耗携程账户额度。")
        }
        .confirmationDialog("清除这台设备的携程授权码？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清除授权码", role: .destructive, action: clearCredential)
            Button("取消", role: .cancel) {}
        } message: {
            Text("携程查询会停用。之后可重新输入授权码。")
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("收起键盘") { keyFocused = false }
            }
        }
        .onAppear { refreshConfiguration() }
        .onChange(of: locked) { _, value in
            if value { confirmingEnable = false; confirmingClear = false; keyFocused = false }
        }
        .onChange(of: phase) { _, value in
            if value != .active { confirmingEnable = false; confirmingClear = false; keyDraft = "" }
        }
        .onDisappear {
            keyDraft = ""; keyFocused = false
            confirmingEnable = false; confirmingClear = false
        }
    }

    private func refreshConfiguration() {
        hasCredential = CtripStore.hasCredential
        enabled = CtripStore.enabled && hasCredential
    }

    private func requestEnabled(_ value: Bool) {
        guard !controlsLocked else { return }
        keyFocused = false
        if value {
            guard CtripStore.hasCredential else {
                failed = true; message = "请先保存携程授权码。"; refreshConfiguration(); return
            }
            confirmingEnable = true
        } else {
            CtripStore.enabled = false; enabled = false
            message = "携程查询已停用。"; failed = false
        }
    }

    private func enableAfterConsent() {
        guard !controlsLocked, phase == .active, CtripStore.hasCredential else { refreshConfiguration(); return }
        CtripStore.enabled = true
        model.settings.systemToolsEnabled = true
        refreshConfiguration(); failed = false; message = "携程查询已开启。"
    }

    private func saveCredential() {
        guard !controlsLocked else { return }
        let value = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try CtripStore.saveAPIKey(value)
            CtripStore.enabled = false
            keyDraft = ""; keyFocused = false
            refreshConfiguration(); failed = false; message = "授权码已保存，请开启携程查询。"
        } catch {
            failed = true; message = "授权码保存失败，请检查格式后重试。"
        }
    }

    private func clearCredential() {
        guard !controlsLocked else { return }
        do {
            try CtripStore.saveAPIKey("")
            CtripStore.enabled = false
            keyDraft = ""; keyFocused = false
            refreshConfiguration(); failed = false; message = "授权码已清除，携程查询已停用。"
        } catch {
            refreshConfiguration()
            failed = true; message = "授权码清除失败，请重试。"
        }
    }

}
