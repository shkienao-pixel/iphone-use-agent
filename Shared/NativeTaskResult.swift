import Foundation
import CoreFoundation

/// Presentation of an actual completed native call, never a model plan.
struct NativeTaskResult: Codable, Equatable, Identifiable {
    enum App: String, Codable { case alarm, calendar, reminders, notes, health, contacts, photos, music, location, content }
    let id: String
    let app: App
    let operation: String
    let title: String
    let value: String
    let detail: String
    let notice: String
    let date: Date?
    let endDate: Date?
    let slot: String

    static func retained(_ old: [Self], adding result: Self) -> [Self] {
        guard !old.contains(where: { $0.id == result.id }) else { return old }
        var next = old
        if !result.slot.isEmpty { next.removeAll { $0.slot == result.slot } }
        next.append(result)
        // Keep recent individual writes and latest queries. This is a display
        // window, not a complete receipt inventory or execution authority.
        while next.filter({ $0.app == result.app }).count > 5 {
            if let index = next.firstIndex(where: { $0.app == result.app }) { next.remove(at: index) }
        }
        return Array(next.suffix(40))
    }

    static func completed(operation: String, result: String, title requestedTitle: String?,
                          start requestedStart: String?, eventID: String) -> Self? {
        guard result.utf8.count <= 48_000, !result.hasPrefix("重复请求已跳过") else { return nil }
        func card(_ app: App, _ title: String, _ value: String, _ detail: String = "", _ notice: String = "",
                  date: Date? = nil, endDate: Date? = nil, id: String? = nil, slot: String = "") -> Self {
            Self(id: id ?? eventID, app: app, operation: operation, title: String(title.prefix(160)),
                 value: String(value.prefix(240)), detail: String(detail.prefix(400)), notice: String(notice.prefix(400)),
                 date: date, endDate: endDate, slot: slot)
        }
        func object() -> [String: Any]? {
            // Some legacy tools append a scope notice after one JSON line.
            guard let line = result.components(separatedBy: .newlines).first,
                  let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        func number(_ value: Any?) -> String? {
            guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
            return value.stringValue
        }
        func writeParts(_ prefix: String) -> (String, [String], String)? {
            guard result.hasPrefix(prefix) else { return nil }
            let parts = String(result.dropFirst(prefix.count)).components(separatedBy: " · ")
            guard let last = parts.last, last.hasPrefix("回执 "), let id = UUID(uuidString: String(last.dropFirst(3))) else { return nil }
            return (id.uuidString, Array(parts.dropLast()), prefix)
        }
        switch operation {
        case "alarm_create":
            guard let (id, parts, _) = writeParts("已添加 Sela 闹钟："), parts.count >= 2,
                  let date = parseDate(parts.last!) else { return nil }
            let title = parts.dropLast().joined(separator: " · ")
            guard !title.isEmpty else { return nil }
            return card(.alarm, title, "已设置", "单次闹钟", "创建时的结果 · 仅 Sela 自己的闹钟", date: date, id: id)
        case "calendar_create":
            guard let (id, parts, _) = writeParts("已添加日程："), parts.count >= 3,
                  parts.last!.hasPrefix("所属日历：") else { return nil }
            let hasEnd = parts[parts.count - 2].hasPrefix("结束：")
            let suffix = hasEnd ? 3 : 2
            guard parts.count > suffix, let date = parseDate(parts[parts.count - suffix]) else { return nil }
            let end = hasEnd ? parseDate(String(parts[parts.count - 2].dropFirst(3))) : nil
            guard !hasEnd || (end != nil && end! > date) else { return nil }
            return card(.calendar, parts.dropLast(suffix).joined(separator: " · "), "已添加日程",
                        String(parts.last!.dropFirst(5)), "创建时的结果", date: date, endDate: end, id: id)
        case "reminder_create":
            guard let (id, parts, _) = writeParts("已添加提醒："), parts.count >= 2,
                  parts.last!.hasPrefix("所属列表：") else { return nil }
            let hasDue = parts.count >= 3 && parts[parts.count - 2].hasPrefix("提醒时间：")
            let date = hasDue ? parseDate(String(parts[parts.count - 2].dropFirst(5))) : nil
            guard !hasDue || date != nil else { return nil }
            return card(.reminders, parts.dropLast(hasDue ? 2 : 1).joined(separator: " · "), "已添加提醒",
                        String(parts.last!.dropFirst(5)), hasDue ? "创建时的结果" : "创建时的结果 · 未返回提醒时间", date: date, id: id)
        case "notes_create":
            guard let value = object(), value["source"] as? String == "iPhone Shortcuts / Apple Notes",
                  value["shortcut_completed"] as? Bool == true, value["output_matches_requested_text"] as? Bool == true,
                  let id = value["receipt_id"] as? String, UUID(uuidString: id) != nil,
                  let title = requestedTitle, !title.isEmpty, let folder = value["expected_folder"] as? String else { return nil }
            return card(.notes, title, "已创建备忘录", "目标文件夹：" + folder,
                        "快捷指令已完成，回传原文一致；未独立核对文件夹或云同步", id: id)
        case "health_query":
            guard let value = object(), value["source"] as? String == "HealthKit",
                  value["coverage"] as? String == "visible_data_only", let type = value["type"] as? String,
                  let start = value["start"] as? String, let end = value["end"] as? String,
                  parseDate(start) != nil, parseDate(end) != nil else { return nil }
            let notice = "仅可见数据；空结果可能是没有记录或未允许读取，不作医学结论"
                + ((value["truncated"] as? Bool == true) ? "；结果已截断" : "")
            switch type {
            case "steps":
                let steps = value["has_visible_data"] as? Bool == true ? number(value["steps"]) : nil
                return card(.health, "步数", steps.map { $0 + " 步" } ?? "暂无可见数据", start + " — " + end, notice,
                            date: parseDate(start), slot: "health.steps")
            case "sleep":
                let seconds = number(value["asleep_seconds"]).flatMap(Double.init)
                let duration = seconds.flatMap { $0.isFinite && $0 >= 0 ? String(format: "%.1f 小时", $0 / 3600) : nil }
                return card(.health, "睡眠", duration ?? "暂无可见睡眠时长", start + " — " + end, notice,
                            date: parseDate(start), slot: "health.sleep")
            case "workouts":
                guard let count = number(value["returned_count"]) else { return nil }
                return card(.health, "运动记录", count + " 条可见记录", start + " — " + end, notice,
                            date: parseDate(start), slot: "health.workouts")
            default: return nil
            }
        case "alarm_list":
            guard let first = result.components(separatedBy: .newlines).first, let data = first.data(using: .utf8),
                  let alarms = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  result.contains("本 App 闹钟总数：") else { return nil }
            return card(.alarm, "Sela 的闹钟", "返回 \(alarms.count) 项", "仅本 App 管理的闹钟",
                        "查询时的结果，最多返回 20 项", slot: "alarm.list")
        case "calendar_search", "reminder_search", "contact_search", "photo_search", "music_search":
            guard let value = object(), let matches = value["matches"] as? [[String: Any]],
                  let count = number(value["matched_count"] ?? value["total"] ?? value["returned_count"]) else { return nil }
            let app: App, title: String, notice: String
            switch operation {
            case "calendar_search": app = .calendar; title = "日程"; notice = "查询时的匹配日程"
            case "reminder_search": app = .reminders; title = "提醒事项"; notice = "查询时的匹配提醒"
            case "contact_search": app = .contacts; title = "联系人"; notice = "仅已授权的联系人"
            case "photo_search": app = .photos; title = "照片资料"; notice = "仅已授权的照片元数据，不含图像内容"
            default:
                guard value["source"] as? String == "Music library" else { return nil }
                app = .music; title = "音乐资料库"; notice = "本机已授权资料库，未搜索在线曲库"
            }
            let names = matches.prefix(3).compactMap { ($0["title"] ?? $0["name"] ?? $0["file"]) as? String }
            return card(app, title, count + " 项匹配", names.joined(separator: "、"),
                        notice + ((value["truncated"] as? Bool == true) ? "；结果已截断" : ""),
                        date: requestedStart.flatMap(parseDate), slot: operation)
        case "music_play", "music_pause", "music_resume", "music_status":
            guard let value = object(), value["source"] as? String == "Sela Music player",
                  value["queue_owner"] as? String == "Sela", let state = value["state"] as? String else { return nil }
            let track = value["track"] as? [String: Any]
            let labels = ["playing": "正在播放", "paused": "已暂停", "stopped": "已停止", "interrupted": "播放被中断", "seeking": "正在跳转", "unknown": "状态未知"]
            guard let label = labels[state] else { return nil }
            return card(.music, track?["title"] as? String ?? "Sela 播放队列", label,
                        track?["artist"] as? String ?? "", "系统返回的播放状态 · 仅 Sela 队列", slot: "music.player")
        case "location_current":
            guard let value = object(), value["source"] as? String == "CoreLocation",
                  let latitude = value["latitude"] as? NSNumber, let longitude = value["longitude"] as? NSNumber,
                  latitude.doubleValue.isFinite, longitude.doubleValue.isFinite,
                  (-90...90).contains(latitude.doubleValue), (-180...180).contains(longitude.doubleValue) else { return nil }
            return card(.location, "本次位置", "大致位置", String(format: "%.3f, %.3f", latitude.doubleValue, longitude.doubleValue),
                        "获取时的位置，不持续追踪", date: (value["timestamp"] as? String).flatMap(parseDate), slot: "location.current")
        case "content_create", "content_status", "content_prepare_clipboard":
            guard let value = object(), let reference = value["artifact_ref"] as? String,
                  reference.split(separator: ":").count == 3,
                  UUID(uuidString: String(reference.split(separator: ":")[1])) != nil,
                  reference.split(separator: ":")[2].count == 64, let title = value["title"] as? String,
                  let size = value["utf8_bytes"] as? String, Int(size) != nil else { return nil }
            guard reference.hasPrefix("content:"), reference.split(separator: ":")[2].allSatisfy({ $0.isHexDigit }) else { return nil }
            if operation == "content_prepare_clipboard" {
                guard value["last_preparation"] as? String == "prepared", value["current_session_lease"] as? String == "prepared" else { return nil }
            }
            let state = operation == "content_prepare_clipboard" ? "已准备本机剪贴板" : "本机内容已保存"
            let notice = operation == "content_prepare_clipboard"
                ? "仅准备本机剪贴板，不代表已在目标 App 粘贴或发送" : "仅 Sela 本机内容，不是系统备忘录"
            return card(.content, title, state, size + " 字节", notice, id: eventID, slot: "content:" + reference)
        default: return nil
        }
    }

    static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
