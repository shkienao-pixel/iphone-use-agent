import SwiftUI

struct PreparationView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    let navigate: (WorkspaceDestination) -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("准备你的第一项任务").font(.title2.weight(.semibold))
                    Text(model.settings.toolsOnly == true ? "确认模型与数据授权，工具操作将逐项确认。" : "连接模型和配件，让助手了解你的屏幕。").font(.subheadline).foregroundStyle(.secondary)
                    step(1, "选择模型服务", detail: "使用你自己的 API Key，或配置可信的兼容接口。", done: model.modelReady) { navigate(.settings) }
                    if model.settings.toolsOnly != true {
                    step(2, "连接 AgentMouse", detail: "手机需要将配件识别为辅助触控鼠标。", done: model.ble.ready || model.settings.previewOnly) { navigate(.device) }
                    step(3, "完成定位校准", detail: "当前配件校准通过后，助手才能准确点击。", done: model.calibrationReady || model.settings.previewOnly) { navigate(.device) }
                    }
                    step(4, "确认 AI 数据使用", detail: "接收方：\(PrivacyConsent.recipient(model.settings))。任务会发送画面、任务文字与行动摘要。", done: model.consentReady) { model.requestConsent() }
                    if model.settings.toolsOnly != true { step(5, "开启整屏共享", detail: "在系统窗口中选择整屏；结束后可随时停止共享。", done: model.capture.running && model.capture.frame?.fullDisplay == true) { navigate(.screenShare) } }
                    if model.preparationReady {
                        Label("已准备就绪，回到任务页开始", systemImage: "checkmark.circle").font(.headline)
                    }
                    Text("需要 iOS 27。仅系统工具模式无需配件或共享；视觉执行需配件、校准和整屏共享，预览模式只生成计划。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }.navigationTitle("使用准备").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("返回任务") { navigate(.tasks) } } }
        }.tint(AgentPalette.accent).agentSheetStyle()
    }
    private func step(_ number: Int, _ title: String, detail: String, done: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(AgentPalette.surface).frame(width: 36, height: 36)
                    if done { Image(systemName: "checkmark") } else { Text("\(number)").font(.subheadline.weight(.semibold)) }
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0); Image(systemName: "chevron.right").foregroundStyle(.secondary).padding(.top, 10)
            }.frame(maxWidth: .infinity, alignment: .leading).agentPanel()
        }.buttonStyle(AgentPressStyle()).accessibilityLabel("第 \(number) 步，\(title)，\(done ? "已完成" : "待准备")")
    }
}
