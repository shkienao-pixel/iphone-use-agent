import SwiftUI

struct TaskNotificationsView: View {
    @ObservedObject var notifications: TaskNotificationsController
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AgentPageIntro(title: "任务有结果时提醒你", subtitle: "完成、执行中断、需要处理或等待确认时提醒。", icon: "bell.badge")
            AgentCard {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("任务通知", isOn: Binding(get: { notifications.enabled }, set: { value in
                        Task { await notifications.setEnabled(value) }
                    })).tint(AgentPalette.accent).disabled(notifications.requesting)
                        .accessibilityIdentifier("notifications.enabled")
                    if notifications.requesting { ProgressView("正在请求系统授权") }
                    Text(notifications.status).font(.subheadline).foregroundStyle(AgentPalette.secondaryText)
                        .accessibilityIdentifier("notifications.authorization")
                    Text("通知会显示任务标题和状态。在 App 前台时不重复弹出横幅；点击只打开对应记录，继续执行仍由你决定。")
                        .font(.caption).foregroundStyle(AgentPalette.secondaryText)
                    Button("打开系统通知设置", action: notifications.openSettings)
                        .accessibilityIdentifier("notifications.systemSettings")
                }
            }
            if !notifications.error.isEmpty { AgentNotice(text: notifications.error, error: true) }
            Text("任务通知使用本机系统通知，不会延长后台运行时间。未运行的任务不会因开启通知而自动开始。")
                .font(.caption).foregroundStyle(AgentPalette.secondaryText)
        }.task { await notifications.refreshAuthorization() }
    }
}
