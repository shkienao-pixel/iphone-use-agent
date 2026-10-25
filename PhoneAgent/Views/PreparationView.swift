import SwiftUI

struct PreparationView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    let navigate: (WorkspaceDestination) -> Void
    var onModelSetup: (() -> Void)? = nil
    @State private var confirmingAssistiveTouch = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("自动检查使用准备").font(.title2.weight(.semibold))
                    Text("配置保存后会复用，只处理当前缺少的项目。").font(.subheadline).foregroundStyle(.secondary)
                    if model.preparingAutomatically {
                        ProgressView(model.automaticPreparationStatus).frame(maxWidth: .infinity, alignment: .leading)
                        Button("取消准备") { model.cancelAutomaticPreparation() }.buttonStyle(AgentButtonStyle(primary: false))
                    } else {
                        Button { model.prepareAutomatically() } label: {
                            Label(model.preparationReady ? "检查已保存配置" : "一键准备", systemImage: "wand.and.stars")
                        }.buttonStyle(AgentButtonStyle()).disabled(model.interactionBusy || model.executor.calibrationInProgress)
                        if !model.automaticPreparationStatus.isEmpty { AgentNotice(text: model.automaticPreparationStatus) }
                    }
                    step(1, "选择模型服务", detail: "使用你自己的 API Key，或配置可信的兼容接口。", done: model.modelReady) {
                        if let onModelSetup { onModelSetup() } else { navigate(.settings) }
                    }
                    if model.settings.toolsOnly != true {
                    step(2, "辅助触控", detail: model.assistiveTouchStatusText, done: model.assistiveTouchReady || model.settings.previewOnly) { model.prepareAutomatically() }
                    if model.needsAssistiveTouchConfirmation {
                        Text("请先在系统设置核对辅助触控已开启，再确认本次使用。配件、校准和共享仍会继续检查。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("核对本次辅助触控设置") { confirmingAssistiveTouch = true }
                            .buttonStyle(AgentButtonStyle(primary: false)).disabled(!model.canConfirmAssistiveTouch)
                    }
                    step(3, "连接 AgentMouse", detail: "手机需要将配件识别为辅助触控鼠标。", done: model.ble.ready || model.settings.previewOnly) { navigate(.device) }
                    step(4, "定位校准", detail: "自动检查当前配件与已保存参数；需要时自动完成 21 步测量并保存。", done: model.calibrationReady || model.settings.previewOnly) { model.prepareAutomatically() }
                    }
                    step(5, "确认 AI 数据使用", detail: "接收方：\(PrivacyConsent.recipient(model.settings))。任务会发送画面、任务文字与行动摘要。", done: model.consentReady) { model.requestConsent() }
                    if model.settings.toolsOnly != true { step(6, "开启整屏共享", detail: "在系统窗口中选择整屏；结束后可随时停止共享。", done: model.capture.running && model.capture.frame?.fullDisplay == true) { navigate(.screenShare) } }
                    if model.preparationReady {
                        Label("已准备就绪，回到任务页开始", systemImage: "checkmark.circle").font(.headline)
                    }
                    Text("首次系统配对、辅助触控开关和整屏共享需你确认。共享结束后重新开启仍需系统确认；修改指针速度后请重新校准。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }.navigationTitle("使用准备").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("返回任务") { navigate(.tasks) } } }
        }.tint(AgentPalette.accent).agentSheetStyle()
        .confirmationDialog("已核对这部手机的辅助触控设置？", isPresented: $confirmingAssistiveTouch, titleVisibility: .visible) {
            Button("已核对开关开启，继续本次准备") { model.confirmAssistiveTouchForCurrentPreparation() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请先在系统设置确认辅助触控开关已开启。此确认只用于本次配件、校准与共享；停止、换配件或共享变化后需重新核对。")
        }
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
        }.buttonStyle(AgentPressStyle()).disabled(model.interactionBusy).accessibilityLabel("\(title)，\(done ? "已完成" : "待准备")")
    }
}
