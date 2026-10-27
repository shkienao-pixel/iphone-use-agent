import SwiftUI
import UIKit

/// Public ActivityKit exposes create availability, not a first-permission state.
/// This guide never infers that a created activity is already visible on screen.
struct TaskActivitySetupView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    private let states = [("observing", "思考"), ("acting", "执行"), ("needsUser", "等你"),
                          ("paused", "暂停"), ("completed", "完成"), ("stale", "待核对")]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                    Button {
                        if model.taskActivity.previewing { model.taskActivity.updatePreview(phase: state.0) }
                        else { Task { await model.startTaskActivityPreview(phase: state.0) } }
                    } label: {
                        VStack(spacing: 4) {
                            SelaIslandPortrait(phase: state.0, width: 34)
                                .frame(width: 40, height: 40).background(.black, in: Circle())
                            Text(state.1).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(.plain)
                        .disabled(model.taskActivityPreviewBlocked || !model.taskActivity.activitiesAvailable)
                        .accessibilityLabel("预览“" + state.1 + "”角色")
                }
            }.accessibilityElement(children: .contain)
            Text("首次使用时，锁屏或下拉通知中心，找到 Sela 实时活动卡片并点“允许”，角色才会出现在灵动岛。")
                .font(.caption).foregroundStyle(AgentPalette.secondaryText)
            if !model.taskActivity.activitiesAvailable {
                Text("系统已关闭实时活动。请在系统设置中检查 Sela 的实时活动开关。")
                    .font(.caption).foregroundStyle(AgentPalette.secondaryText)
                Button("打开系统设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }.buttonStyle(.bordered)
                    .accessibilityIdentifier("activity.settings")
            }
            if model.taskActivity.previewing {
                Button("结束角色预览") { model.taskActivity.stopPreview() }
                    .buttonStyle(.bordered).accessibilityIdentifier("activity.preview.stop")
            } else {
                Button("预览 Sela 灵动岛") { Task { await model.startTaskActivityPreview() } }
                    .buttonStyle(.bordered).disabled(model.taskActivityPreviewBlocked || !model.taskActivity.activitiesAvailable)
                    .accessibilityIdentifier("activity.preview.start")
                if model.taskActivityPreviewBlocked, model.settings.liveTaskStatus != false {
                    Text("已有任务状态正在显示。完成或停止任务后可预览，实际任务会继续使用原来的状态卡片。")
                        .font(.caption).foregroundStyle(AgentPalette.secondaryText)
                }
            }
            if !model.taskActivity.previewMessage.isEmpty {
                Text(model.taskActivity.previewMessage).font(.caption).foregroundStyle(AgentPalette.secondaryText)
                    .accessibilityIdentifier("activity.preview.message")
            }
            Text("预览不查询或执行任务；返回 Sela 会自动结束。预览已创建时，仍可能需要在锁屏点“允许”。")
                .font(.caption2).foregroundStyle(AgentPalette.secondaryText)
        }
        .onAppear { model.taskActivity.refreshAvailability() }
    }
}
