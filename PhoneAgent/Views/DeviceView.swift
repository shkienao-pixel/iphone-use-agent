import SwiftUI

struct DeviceView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    let onCalibration: () -> Void
    var onScreenShare: (() -> Void)? = nil
    @State private var pendingWorkflows: [PhoneWorkflowRecord] = []
    @State private var reviewMessage = ""
    @State private var confirmingAssistiveTouch = false
    private var busy: Bool { model.interactionBusy }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AgentPageIntro(title: "连接 ESP32 与蓝牙鼠标", subtitle: "统一检查控制通道与鼠标状态，校准后开始操控。")
                VStack(alignment: .leading, spacing: 12) {
                    Text("自动检查与配置").font(.headline)
                    Label(model.assistiveTouchStatusText, systemImage: model.assistiveTouchReady ? "checkmark.circle" : "hand.point.up.left")
                    if model.needsAssistiveTouchConfirmation {
                        Button("核对本次辅助触控设置") { confirmingAssistiveTouch = true }
                            .buttonStyle(AgentButtonStyle(primary: false)).disabled(!model.canConfirmAssistiveTouch)
                    }
                    Label(model.ble.ready ? "配件已就绪" : "配件等待连接", systemImage: model.ble.ready ? "checkmark.circle" : "computermouse")
                    Label(model.calibrationReady ? "当前配件校准可复用" : "当前配件需要校准", systemImage: model.calibrationReady ? "checkmark.circle" : "scope")
                    if model.preparingAutomatically {
                        ProgressView(model.automaticPreparationStatus)
                        Button("取消准备") { model.cancelAutomaticPreparation() }.buttonStyle(AgentButtonStyle(primary: false))
                    } else {
                        Button { model.prepareAutomatically() } label: { Label("一键准备", systemImage: "wand.and.stars") }
                            .buttonStyle(AgentButtonStyle()).disabled(busy || model.executor.calibrationInProgress)
                        if !model.automaticPreparationStatus.isEmpty { AgentNotice(text: model.automaticPreparationStatus) }
                    }
                    Text("自动连接并复用有效校准；缺少校准时自动测量并保存。首次配对及系统共享仍需确认。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.agentPanel()
                if !pendingWorkflows.isEmpty || model.engine.phoneHarness?.hasPendingReview == true {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("待核验的操作").font(.headline)
                            Spacer()
                            Button("刷新", action: refreshWorkflows)
                        }
                        Text("先到实际会话检查已有内容，再记录核对结果。这里不会自动补发。")
                            .font(.footnote).foregroundStyle(.secondary)
                        ForEach(pendingWorkflows, id: \.operationID) { record in
                            VStack(alignment: .leading, spacing: 10) {
                                Text("文件传输助手").font(.subheadline.weight(.medium))
                                Text(record.text).font(.footnote).textSelection(.enabled)
                                Text(record.detail).font(.caption).foregroundStyle(.secondary)
                                Button("已确认仅发送一次") { review(record, as: .confirmedSubmitted) }
                                Button("已确认没有发送") { review(record, as: .confirmedNotSubmitted) }
                            }.disabled(!model.engine.executionSettled || busy)
                        }
                        if pendingWorkflows.isEmpty {
                            Text("操作记录暂时无法读取，已停止自动输入。请先保留原始记录并核查存储问题。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if !reviewMessage.isEmpty { Text(reviewMessage).font(.footnote) }
                    }.agentPanel()
                }
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 15) {
                        Image(systemName: "computermouse.fill").font(.system(size: 32)).foregroundStyle(AgentPalette.accent)
                            .frame(width: 68, height: 68).background(AgentPalette.accent.opacity(0.075), in: RoundedRectangle(cornerRadius: 22))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("AgentMouse").font(.title3.weight(.semibold))
                            Text(model.ble.state).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.ble.ready { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    }
                    if model.ble.connected {
                        if model.ble.ready {
                            Text(model.ble.bufferedMotionReady ? "鼠标移动已就绪" : "请升级配件固件")
                                .font(.caption).foregroundStyle(.secondary)
                            Label(model.ble.keyboardReady ? "蓝牙键盘已就绪" :
                                (model.ble.status?.keyboardSupported == true ? "等待系统连接键盘" : "配件尚未支持键盘"),
                                systemImage: "keyboard").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Label(model.ble.ready ? "鼠标已就绪" : "连接中", systemImage: "circle.fill").font(.caption)
                            Spacer()
                            Button("刷新") { model.ble.refresh() }.disabled(busy)
                            Button("断开", role: .destructive) { model.stop(); Task { await model.ble.release(); model.ble.disconnect() } }
                        }.font(.caption)
                    } else {
                        Button(model.ble.scanning ? "停止查找" : "连接 AgentMouse") {
                            if model.ble.scanning { model.ble.stopScan() } else { model.ble.scan() }
                        }.buttonStyle(AgentButtonStyle()).disabled(busy)
                        ForEach(model.ble.devices) { device in
                            Button { model.ble.connect(device) } label: {
                                HStack { Label(device.name, systemImage: "dot.radiowaves.left.and.right"); Spacer(); Image(systemName: "chevron.right").font(.caption) }
                                    .font(.subheadline).frame(minHeight: 48)
                            }.disabled(busy)
                        }
                    }
                    if !model.ble.error.isEmpty { AgentNotice(text: model.ble.error, error: true) }
                }.padding(20).background(AgentPalette.inset, in: RoundedRectangle(cornerRadius: 18))
                if !model.ble.ready {
                    Button("打开系统配对设置") { model.openAccessorySettings() }
                        .buttonStyle(AgentButtonStyle(primary: false)).disabled(busy)
                    DisclosureGroup("连接帮助") { VStack(alignment: .leading, spacing: 14) {
                        AgentSectionTitle(title: "首次连接", subtitle: "系统配对与 App 连接分两步；首次完成后通常无需重复。")
                        connectionStep(1, "在 iOS 中配对", "设置 → 辅助功能（或“无障碍”）→ 触控 → 辅助触控 → 设备 → 蓝牙设备，选择 AgentMouse。系统询问时点“配对”。")
                        connectionStep(2, "回到 Sela", "配对成功后返回此页，再点“连接 AgentMouse”。看到“鼠标已就绪”后再开始校准。")
                        connectionStep(3, "连接超时", "确认配件有电且 iPhone 蓝牙已开启；刚配对后可关闭再开启辅助触控，然后回此页重试。")
                        Link("查看 Apple 官方指针设备说明", destination: URL(string: "https://support.apple.com/zh-cn/111775")!)
                            .font(.footnote.weight(.medium))
                    }.padding(.top, 12) }.agentPanel()
                }
                VStack(alignment: .leading, spacing: 15) {
                    AgentSectionTitle(title: "把每一次点击对准", subtitle: "首次使用或更改指针速度后，校准一次。")
                    if let c = model.executor.calibration {
                        HStack {
                            Label(model.calibrationReady ? "当前配件已校准" : "需要校准当前配件", systemImage: "scope").foregroundStyle(AgentPalette.accent)
                        }.font(.footnote)
                        if model.calibrationReady { Text("最大误差 \(c.validationError, specifier: "%.1f") 点").font(.caption).foregroundStyle(.secondary) }
                    }
                    Button(model.calibrationReady ? "重新校准" : "开始校准") { onCalibration() }.buttonStyle(AgentButtonStyle(primary: false)).disabled(!model.ble.ready || busy || model.executor.calibrationInProgress)
                    DisclosureGroup("校准前的准备") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("保持竖屏，在 21 步校准过程中不要触碰屏幕。")
                            Text("每次定位先回左上角，再斜向移动。建议关闭“吸附到项目”，并固定指针速度。")
                            if let c = model.executor.calibration, model.calibrationReady, let rms = c.validationRMS, let drift = c.returnDrift {
                                Text("最近校准：RMS \(rms, specifier: "%.1f") 点 · 往返漂移 \(drift, specifier: "%.1f") 点")
                            }
                        }.font(.footnote).foregroundStyle(.secondary).padding(.top, 12)
                    }.font(.subheadline)
                }.padding(20).background(AgentPalette.inset, in: RoundedRectangle(cornerRadius: 18))
                if let onScreenShare {
                    Button(action: onScreenShare) {
                        HStack(spacing: 14) {
                            Image(systemName: "rectangle.on.rectangle").font(.system(size: 22))
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("屏幕共享").font(.headline)
                                Text(model.capture.running && model.capture.frame?.fullDisplay == true ? "手机整屏已共享" : "查看画面并管理屏幕共享")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.capture.running && model.capture.frame?.fullDisplay == true {
                                Circle().fill(.green).frame(width: 7, height: 7)
                            }
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                            .background(AgentPalette.inset, in: RoundedRectangle(cornerRadius: 18))
                    }.buttonStyle(AgentPressStyle()).foregroundStyle(.primary)
                        .accessibilityIdentifier("connections.screenShare")
                }
                VStack(alignment: .leading, spacing: 13) {
                    DisclosureGroup("返回桌面：先验证辅助触控映射") {
                    VStack(alignment: .leading, spacing: 14) {
                    Toggle("我已验证中键可以回到主屏幕", isOn: Binding(
                        get: { model.settings.homeButtonIsMapped(to: model.ble.selectedID) },
                        set: { model.settings.homeMappedPeripheralID = $0 ? model.ble.selectedID : nil }
                    )).tint(.green).disabled(busy || model.ble.selectedID == nil)
                    Text("先在 iPhone 设置 → 辅助功能 → 触控 → 辅助触控 → 设备 → AgentMouse 中，把中键分配为“主屏幕”。手动按一次中键，确认确实回到桌面后，再开启上面的选项。每个配件需单独设置。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("未开启时，助手会尝试点击画面上可见的辅助触控按钮，再观察菜单并点“主屏幕”；看不到菜单按钮时会停下来请你显示，不会反复盲按。")
                        .font(.footnote).foregroundStyle(.secondary)
                    }.padding(.top, 14)
                    }.font(.subheadline)
                }.padding(20).background(AgentPalette.inset, in: RoundedRectangle(cornerRadius: 18))
                if !model.notice.isEmpty { AgentNotice(text: model.notice) }

            }.padding(20)
        }
        .onAppear { refreshWorkflows(); model.ble.ensureConnection() }
        .confirmationDialog("已核对这部手机的辅助触控设置？", isPresented: $confirmingAssistiveTouch, titleVisibility: .visible) {
            Button("已核对开关开启，继续本次准备") { model.confirmAssistiveTouchForCurrentPreparation() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请先在系统设置确认辅助触控开关已开启。此确认只用于本次配件、校准与共享；停止、换配件或共享变化后需重新核对。")
        }
    }
    private func refreshWorkflows() {
        pendingWorkflows = (model.engine.phoneHarness as? PhoneHarnessRuntime)?.pendingWorkflowRecords ?? []
    }
    private func review(_ record: PhoneWorkflowRecord, as resolution: PhoneWorkflowReviewResolution) {
        guard model.engine.executionSettled, !busy,
              let harness = model.engine.phoneHarness as? PhoneHarnessRuntime else { return }
        do {
            try harness.resolveReviewed(operationID: record.operationID, resolution: resolution)
            reviewMessage = "已记录你的核对结果；没有执行任何点击、输入或发送。"
            refreshWorkflows()
        } catch { reviewMessage = error.localizedDescription }
    }
    private func connectionStep(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.caption.weight(.semibold)).foregroundStyle(.primary)
                .frame(width: 24, height: 24).background(AgentPalette.surface, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
