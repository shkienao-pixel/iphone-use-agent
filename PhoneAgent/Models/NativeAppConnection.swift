import Foundation

enum NativeAppConnection: String, CaseIterable, Identifiable, Hashable {
    case calendar, contacts, health, music, photos, reminders, alarm, location, notes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .calendar: "日历"
        case .contacts: "通讯录"
        case .health: "健康"
        case .music: "Apple Music"
        case .photos: "照片"
        case .reminders: "提醒事项"
        case .alarm: "Sela 闹钟"
        case .location: "位置"
        case .notes: "备忘录"
        }
    }
    var detail: String {
        switch self {
        case .calendar: "查询日程、安排时间"
        case .contacts: "查找联系人和联系方式"
        case .health: "查询睡眠、步数与运动"
        case .music: "查找歌曲、播放与暂停"
        case .photos: "查找已授权照片的资料"
        case .reminders: "查询待办、添加提醒"
        case .alarm: "查看和创建本 App 的单次闹钟"
        case .location: "单次获取当前大致位置"
        case .notes: "通过已配置的快捷指令创建"
        }
    }
    var purpose: String {
        let detail = switch self {
        case .calendar: "允许 Sela 在你确认的任务中查询日程或添加安排。需要读取日程时，必须授予完整日历访问权限。"
        case .contacts: "允许 Sela 在你确认的任务中查找联系人的姓名、电话和邮箱。可以只允许访问指定联系人。"
        case .health: "按你的任务查询指定时间内的步数、睡眠时长和运动记录。只读取你选择的数据类型，并保留已完成读取的核对信息，便于长任务汇总。"
        case .music: "在你确认后，查找资料库中的歌曲，在 Sela 中播放、暂停或继续播放。在线曲库搜索和购买订阅不在此入口中提供。"
        case .photos: "允许 Sela 在你确认的任务中按日期查找照片资料。可以只授权部分照片；现有查询仅返回资料，不会自动读取整库图像。"
        case .reminders: "允许 Sela 在你确认的任务中查询待办或添加提醒，使用与系统提醒事项相同的数据。"
        case .alarm: "按你的任务创建单次闹钟，或查看 Sela 自己创建的闹钟。首次使用需系统授权。"
        case .location: "在你确认后，单次获取约至百米的当前位置和误差范围，供附近服务等任务使用。可以选择大致位置，不持续定位。"
        case .notes: "通过本机快捷指令，在固定文件夹中按任务创建备忘录。首次系统授权按实际要求处理。"
        }
        return detail + " 退到后台后，下一步会等你返回 Sela 再自动继续；停止任务后不会自行恢复。"
    }
    var brandAsset: String? { self == .location ? nil : "Native-" + rawValue }
}

enum NativeConnectionAccess: Equatable {
    case notDetermined, authorized, limited, writeOnly, denied, restricted, reviewed, unavailable, unconfigured, configured
    var title: String {
        switch self {
        case .notDetermined: "未授权"
        case .authorized: "已授权"
        case .limited: "部分授权"
        case .writeOnly: "仅添加"
        case .denied: "未允许"
        case .restricted: "受限制"
        case .reviewed: "已设置"
        case .unavailable: "暂不可用"
        case .unconfigured: "待配置"
        case .configured: "已配置"
        }
    }
    var ready: Bool { self == .authorized || self == .limited || self == .configured }
    var needsSettings: Bool { self == .denied || self == .restricted }
}

enum NativeHealthScope: String, CaseIterable, Identifiable {
    case steps, sleep, workouts
    var id: String { rawValue }
    var title: String {
        switch self { case .steps: "步数"; case .sleep: "睡眠"; case .workouts: "运动记录" }
    }
}
