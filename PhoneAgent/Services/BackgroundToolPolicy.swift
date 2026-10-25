import Foundation

@MainActor enum BackgroundToolPolicy {
    /// Check immediately before execution, under the resource lease. No worker
    /// may open another app or summon an initial system permission dialog.
    static func validate(_ request: SystemToolRequest) throws {
        try request.validate()
        guard request.operation != .notes_create else {
            throw AgentError.message("创建系统备忘录会打开快捷指令，需要在前台单独执行；后台任务已等待你处理")
        }
        guard request.operation != .health_query else {
            throw AgentError.message("健康查询需要核对系统授权流程，请在前台单独执行；后台任务已等待你处理")
        }
        let connection: NativeAppConnection?
        switch request.operation {
        case .calendar_search, .calendar_create: connection = .calendar
        case .reminder_search, .reminder_create: connection = .reminders
        case .contact_search: connection = .contacts
        case .photo_search: connection = .photos
        case .alarm_list, .alarm_create: connection = .alarm
        case .music_search, .music_play, .music_pause, .music_resume, .music_status: connection = .music
        case .location_current: connection = .location
        default: connection = nil
        }
        if let connection {
            NativeConnectionsStore.shared.refresh()
            guard NativeConnectionsStore.shared.state(connection).ready else {
                throw AgentError.message("此原生服务尚未获得系统权限，请先到 App 连接中授权，再继续这项后台任务")
            }
        }
    }
}
