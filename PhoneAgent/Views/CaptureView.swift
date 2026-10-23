import SwiftUI

struct CaptureView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    private var busy: Bool { model.interactionBusy }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AgentPageIntro(title: "共享手机画面", subtitle: "让助手看到当前屏幕。由你开启，随时结束。")
                HStack {
                    Circle().fill(model.capture.running ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                    Text(model.capture.state).font(.subheadline.weight(.medium))
                    Spacer()
                    if model.capture.running { Text("LIVE").font(.caption2.weight(.bold)).foregroundStyle(AgentPalette.accent) }
                }
                Group {
                    if let frame = model.capture.frame {
                        VStack(spacing: 12) {
                            Image(uiImage: frame.image).resizable().scaledToFit().frame(maxHeight: 390)
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                            HStack {
                                Text("\(frame.sourceWidth) × \(frame.sourceHeight)")
                                Spacer(); Text("\(model.capture.fps, specifier: "%.1f") FPS")
                            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(spacing: 18) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 27).stroke(AgentPalette.accent.opacity(0.20), lineWidth: 2).frame(width: 126, height: 220)
                                VStack(spacing: 14) {
                                    Image(systemName: "viewfinder").font(.system(size: 39, weight: .ultraLight)).foregroundStyle(AgentPalette.accent)
                                    Text("等待画面").font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 17)
                            Text("通过系统选择器共享整屏").font(.subheadline.weight(.medium))
                            Text("切换到其他 App 后，助手仍能观察当前画面。")
                                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity)
                    }
                }.agentPanel()
                if model.capture.running {
                    Button("停止屏幕共享", role: .destructive) { model.stop(); model.capture.stop() }.buttonStyle(AgentButtonStyle(primary: false))
                } else {
                    Button { model.capture.start() } label: { Label("共享整屏", systemImage: "rectangle.on.rectangle") }
                        .buttonStyle(AgentButtonStyle()).disabled(model.capture.waitingForPicker || busy)
                }
                if !model.capture.error.isEmpty { AgentNotice(text: model.capture.error, error: true) }
                Text("开始任务后，画面会发送到你配置的模型。停止任务不会结束共享；受保护的内容可能显示为空白。")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 3)
            }.padding(20)
        }
    }
}
