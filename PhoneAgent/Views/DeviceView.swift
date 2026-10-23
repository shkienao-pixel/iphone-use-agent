import SwiftUI

struct DeviceView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    let onCalibration: () -> Void
    private var busy: Bool { model.interactionBusy }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AgentPageIntro(title: "连接 AgentMouse", subtitle: "配件负责点击与输入，校准后开始操控。")
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
                            Button("刷新") { model.ble.refresh() }
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
                    DisclosureGroup("连接帮助") { VStack(alignment: .leading, spacing: 14) {
                        AgentSectionTitle(title: "首次连接", subtitle: "系统配对与 App 连接分两步；首次完成后通常无需重复。")
                        connectionStep(1, "在 iOS 中配对", "设置 → 辅助功能（或“无障碍”）→ 触控 → 辅助触控 → 设备 → 蓝牙设备，选择 AgentMouse。系统询问时点“配对”。")
                        connectionStep(2, "回到 Phone Agent", "配对成功后返回此页，再点“连接 AgentMouse”。看到“鼠标已就绪”后再开始校准。")
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
