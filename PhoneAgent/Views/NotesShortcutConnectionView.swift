import SwiftUI

struct NotesShortcutConnectionView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @ObservedObject private var bridge = NotesShortcutBridge.shared
    @State private var helper = ""
    @State private var folder = ""
    @State private var message = ""
    @State private var failed = false
    private var busy: Bool { bridge.running || model.engine.running || model.engine.releasing || model.voicePending }
    var body: some View {
        ConnectionPage {
            HStack(spacing: 16) {
                NativeConnectionIcon(app: .notes, size: 60)
                Text("备忘录").font(.title2.weight(.semibold))
            }
            Text(NativeAppConnection.notes.purpose).font(.subheadline).foregroundStyle(.secondary)
                .accessibilityIdentifier("native.notes.purpose")
            Text("先在这部 iPhone 的快捷指令中准备“创建备忘录”：内容使用快捷指令输入，固定目标文件夹，并关闭运行后打开备忘录。")
                .font(.subheadline).foregroundStyle(.secondary)
            TextField("创建备忘录的快捷指令名称", text: $helper).agentField()
                .accessibilityIdentifier("native.notes.helper")
            TextField("快捷指令中固定的文件夹名称", text: $folder).agentField()
                .accessibilityIdentifier("native.notes.folder")
            Button("保存连接") {
                do {
                    try bridge.configure(.init(createShortcut: helper, folderName: folder))
                    model.settings.systemToolsEnabled = true; NativeConnectionsStore.shared.refresh()
                    failed = false; message = "已保存配置，首次创建后请核对系统备忘录中的文件夹和正文"
                } catch { failed = true; message = error.localizedDescription }
            }.buttonStyle(AgentButtonStyle()).accessibilityIdentifier("native.notes.save")
            if !message.isEmpty { AgentNotice(text: message, error: failed) }
            Text("按任务直接创建时会切换到快捷指令。系统可能首次要求授权；中断或结果未知时不会自动重复创建。此连接暂不提供查找、修改或删除备忘录。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .disabled(busy)
        .task { if let config = bridge.configuration { helper = config.createShortcut; folder = config.folderName } }
        .accessibilityIdentifier("nativeConnection.notes")
    }
}
