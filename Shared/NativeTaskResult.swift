import Foundation
import CoreFoundation
import CryptoKit

/// Actual post-save EventKit fields. Identifiers are local to this device/store;
/// neither they nor this creation receipt prove later existence or cloud sync.
struct NativeEventWriteReceipt: Codable, Equatable {
    enum Operation: String, Codable { case calendar = "calendar_create", reminder = "reminder_create" }
    let schema_version: Int
    let source: String
    let state: String
    let operation: Operation
    let local_receipt_id: UUID
    let system_item_id: String
    let collection_id: String
    let title: String
    let collection_name: String
    let start: String?
    let end: String?
    let due: String?

    init(operation: Operation, receiptID: UUID, systemItemID: String, collectionID: String,
         title: String, collectionName: String, start: String? = nil, end: String? = nil, due: String? = nil) {
        schema_version = 1; source = "EventKit"; state = "completed"
        self.operation = operation; local_receipt_id = receiptID
        system_item_id = systemItemID; collection_id = collectionID
        self.title = title; collection_name = collectionName
        self.start = start; self.end = end; self.due = due
    }

    private var valid: Bool {
        guard schema_version == 1, source == "EventKit", state == "completed",
              [system_item_id, collection_id, title, collection_name].allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 4096
              }) else { return false }
        switch operation {
        case .calendar:
            guard due == nil, let start, let end,
                  let first = NativeTaskResult.parseDate(start), let last = NativeTaskResult.parseDate(end) else { return false }
            return first < last
        case .reminder:
            return start == nil && end == nil && (due == nil || NativeTaskResult.parseDate(due!) != nil)
        }
    }

    func serialized() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard valid, data.count <= 12_000 else { throw InvalidReceipt() }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ result: String, operation: String) -> Self? {
        let data = Data(result.utf8)
        guard data.count <= 12_000, let receipt = try? JSONDecoder().decode(Self.self, from: data),
              receipt.operation.rawValue == operation, receipt.valid else { return nil }
        return receipt
    }

    private struct InvalidReceipt: LocalizedError {
        var errorDescription: String? { "系统写入已提交，但实际回执字段不完整；请先核对目标 App，未重复创建" }
    }
}

/// Presentation of an actual completed native call, never a model plan.
struct NativeTaskResult: Codable, Equatable, Identifiable, Sendable {
    enum App: String, Codable, Sendable { case alarm, calendar, reminders, notes, health, contacts, photos, music, location, content }
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
    var systemObjectID: String? = nil
    var collectionID: String? = nil

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

    /// Keep completed actions visible when a later verification query returns.
    /// Reordering is presentation only; source objects and stored order survive.
    static func displayOrder(_ results: [Self]) -> [Self] {
        let actions: Set<String> = ["alarm_create", "calendar_create", "reminder_create", "notes_create",
            "content_create", "content_prepare_clipboard", "music_play", "music_pause", "music_resume"]
        let newest = Array(results.reversed())
        return newest.filter { actions.contains($0.operation) } + newest.filter { !actions.contains($0.operation) }
    }

    static func completed(operation: String, result: String, title requestedTitle: String?,
                          start requestedStart: String?, eventID: String) -> Self? {
        guard result.utf8.count <= 48_000, !result.hasPrefix("重复请求已跳过") else { return nil }
        func card(_ app: App, _ title: String, _ value: String, _ detail: String = "", _ notice: String = "",
                  date: Date? = nil, endDate: Date? = nil, id: String? = nil, slot: String = "",
                  systemObjectID: String? = nil, collectionID: String? = nil) -> Self {
            Self(id: id ?? eventID, app: app, operation: operation, title: String(title.prefix(160)),
                 value: String(value.prefix(240)), detail: String(detail.prefix(400)), notice: String(notice.prefix(400)),
                 date: date, endDate: endDate, slot: slot, systemObjectID: systemObjectID, collectionID: collectionID)
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
            if let receipt = NativeEventWriteReceipt.decode(result, operation: operation) {
                return card(.calendar, receipt.title, "已添加日程", receipt.collection_name, "创建时的结果",
                            date: receipt.start.flatMap(parseDate), endDate: receipt.end.flatMap(parseDate),
                            id: receipt.local_receipt_id.uuidString, systemObjectID: receipt.system_item_id,
                            collectionID: receipt.collection_id)
            }
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
            if let receipt = NativeEventWriteReceipt.decode(result, operation: operation) {
                return card(.reminders, receipt.title, "已添加提醒", receipt.collection_name,
                            receipt.due == nil ? "创建时的结果 · 未设置提醒时间" : "创建时的结果",
                            date: receipt.due.flatMap(parseDate), id: receipt.local_receipt_id.uuidString,
                            systemObjectID: receipt.system_item_id, collectionID: receipt.collection_id)
            }
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

/// Host-recorded completion evidence. This data grants no execution authority.
/// It is separate from the bounded display cards and from model-authored logs.
struct TaskCompletionEvidence: Codable, Equatable, Sendable {
    struct Tool: Codable, Equatable, Sendable {
        var operation: String
        var receiptID: String
        var title: String?
        var start: String?
        var end: String?
        var resultSHA256: String
    }
    var version = 1
    var goalSHA256: String
    var tools: [Tool] = []
    var observations = 0
    var inputs = 0
    var postInputObservations = 0
    var lastInputAt: Date?
    var allowsReceiptRecovery = true
    var subtaskReceiptIDs: [String] = []
    var subtaskObservationBoundary = 0

    init(goal: String) { goalSHA256 = Self.digest(goal) }
    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    mutating func observe(confirmedAt: Date) {
        observations = min(1_000_000, observations + 1)
        if let lastInputAt, confirmedAt > lastInputAt { postInputObservations = min(1_000_000, postInputObservations + 1) }
    }
    mutating func input(completedAt: Date) {
        inputs = min(1_000_000, inputs + 1); lastInputAt = completedAt; postInputObservations = 0
    }
    mutating func add(_ tool: Tool) {
        guard !tools.contains(where: { $0.operation == tool.operation && $0.receiptID == tool.receiptID && $0.resultSHA256 == tool.resultSHA256 }) else { return }
        tools.append(tool)
        // Retain operation evidence beyond UI-card eviction without unbounded growth.
        if tools.count > 2_000 { tools.removeFirst(tools.count - 2_000) }
    }
    static func restore(goal: String, persisted: Self?, legacyResults: [NativeTaskResult], receipts: [String]) -> Self {
        var evidence: Self
        if let persisted {
            guard persisted.version == 1, persisted.goalSHA256 == digest(goal), persisted.tools.count <= 2_000,
                  persisted.observations >= 0, persisted.inputs >= 0, persisted.postInputObservations >= 0 else {
                var replacement = Self(goal: goal); replacement.allowsReceiptRecovery = false; return replacement
            }
            evidence = persisted
        } else {
            evidence = Self(goal: goal)
            // Legacy cards are host-built and task-bound, but not a full audit.
            // Only writes with a real system identifier and an explicit title in
            // this unchanged task can establish legacy completion evidence.
            for card in legacyResults where ["calendar_create", "reminder_create"].contains(card.operation) {
                guard card.systemObjectID?.isEmpty == false, card.collectionID?.isEmpty == false,
                      !card.title.isEmpty, goal.contains(card.title), UUID(uuidString: card.id) != nil else { continue }
                evidence.add(Tool(operation: card.operation, receiptID: card.id, title: card.title,
                    start: card.date.map { ISO8601DateFormatter().string(from: $0) },
                    end: card.endDate.map { ISO8601DateFormatter().string(from: $0) }, resultSHA256: digest(card.id + card.operation)))
            }
        }
        for raw in receipts where evidence.allowsReceiptRecovery {
            for operation in ["calendar_create", "reminder_create", "alarm_create", "notes_create", "content_create"] {
                if let tool = recoveredWrite(operation: operation, result: raw) { evidence.add(tool) }
            }
        }
        return evidence
    }
    static func successfulTool(operation: String, result: String, title: String?, start: String?, end: String?,
                               query: String?, artifactReference: String?, content: String?, eventID: String) -> Tool? {
        let prefix = "重复请求已跳过；之前的回执："
        let raw = result.hasPrefix(prefix) ? String(result.dropFirst(prefix.count)) : result
        guard !raw.isEmpty, raw.utf8.count <= 48_000 else { return nil }
        let card = NativeTaskResult.completed(operation: operation, result: raw, title: title, start: start, eventID: eventID)
        let writes: Set<String> = ["calendar_create", "reminder_create", "alarm_create", "notes_create", "content_create", "content_prepare_clipboard"]
        if writes.contains(operation) {
            guard let card else { return nil }
            if let title, card.title.precomposedStringWithCanonicalMapping != title.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping { return nil }
            if let start {
                guard let expected = NativeTaskResult.parseDate(start), let actual = card.date,
                      abs(expected.timeIntervalSince(actual)) < 1 else { return nil }
            }
            if let end {
                guard let expected = NativeTaskResult.parseDate(end), let actual = card.endDate,
                      abs(expected.timeIntervalSince(actual)) < 1 else { return nil }
            }
            if operation == "content_create", let content {
                guard let object = json(raw), let reference = object["artifact_ref"] as? String,
                      reference.hasSuffix(":" + digest(content)), object["utf8_bytes"] as? String == String(content.utf8.count) else { return nil }
            }
            if operation == "content_prepare_clipboard" {
                guard let object = json(raw), object["artifact_ref"] as? String == artifactReference else { return nil }
            }
            return Tool(operation: operation, receiptID: card.id, title: title, start: start, end: end, resultSHA256: digest(raw))
        }
        if ["music_play", "music_pause", "music_resume"].contains(operation) {
            guard let object = json(raw), object["confirmed"] as? Bool == true,
                  object["command"] as? String == operation else { return nil }
            if operation == "music_play" {
                guard let track = object["track"] as? [String: Any], track["id"] as? String == query, track["title"] as? String == title else { return nil }
            }
        }
        if operation == "health_query" {
            guard let object = json(raw), object["type"] as? String == query,
                  object["start"] as? String == start, object["end"] as? String == end else { return nil }
        }
        let servicePrefix = ["ctrip_query": "来源：携程", "meituan_query": "来源：美团官方酒旅", "meituan_paotui": "来源：美团跑腿官方"]
        guard card != nil || servicePrefix[operation].map({ raw.hasPrefix($0) && raw.count > $0.count }) == true else { return nil }
        return Tool(operation: operation, receiptID: card?.id ?? eventID, title: title, start: start, end: end, resultSHA256: digest(raw))
    }
    private static func recoveredWrite(operation: String, result: String) -> Tool? {
        if let receipt = NativeEventWriteReceipt.decode(result, operation: operation) {
            return Tool(operation: operation, receiptID: receipt.local_receipt_id.uuidString, title: receipt.title,
                start: receipt.start ?? receipt.due, end: receipt.end, resultSHA256: digest(result))
        }
        // Alarm text includes the actual scheduled time and host receipt UUID.
        if operation == "alarm_create", let card = NativeTaskResult.completed(operation: operation, result: result,
            title: nil, start: nil, eventID: "unused"), UUID(uuidString: card.id) != nil, let date = card.date {
            return Tool(operation: operation, receiptID: card.id, title: card.title,
                start: ISO8601DateFormatter().string(from: date), end: nil, resultSHA256: digest(result))
        }
        // Notes/content legacy receipts lack a trustworthy request title/body
        // binding here. Let an explicit deduplicated request re-establish it.
        return nil
    }
    private static func json(_ raw: String) -> [String: Any]? {
        guard let line = raw.components(separatedBy: .newlines).first else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }
}

/// A conservative operation-family check, not a natural-language correctness
/// oracle. Only the host may supply evidence; model reason/text is never proof.
enum TaskCompletionPolicy {
    enum Decision: Equatable { case tools, observed, needsUser(String) }
    static func decide(goal: String, toolsOnly: Bool, evidence: TaskCompletionEvidence) -> Decision {
        guard evidence.goalSHA256 == TaskCompletionEvidence.digest(goal) else { return .needsUser("任务要求已经改变，原完成依据不能用于当前要求。") }
        let text = effectiveIntentText(goal.lowercased())
        let required = requiredOperations(text)
        let completed = Set(evidence.tools.map(\.operation))
        let missing = required.subtracting(completed)
        let visualMutation = requiresVisualMutation(text)
        if !missing.isEmpty {
            if !toolsOnly, evidence.inputs > 0, evidence.postInputObservations > 0 { return .observed }
            return .needsUser("尚无匹配的实际工具成功回执：" + missing.sorted().map(operationLabel).joined(separator: "、") + "。没有把模型的结束声明记为完成。")
        }
        if visualMutation {
            guard !toolsOnly, evidence.inputs > 0, evidence.postInputObservations > 0 else {
                return .needsUser("这项操作需要实际输入及操作后的新画面核验，现有观察或其他查询不能证明已经完成。")
            }
            return .observed
        }
        if !required.isEmpty || (toolsOnly && !evidence.tools.isEmpty) { return .tools }
        if !toolsOnly, evidence.observations > 0 {
            let readOnly = clauses(text).contains { !negated($0) && readIntent($0) }
            if readOnly || (evidence.inputs > 0 && evidence.postInputObservations > 0) { return .observed }
        }
        return .needsUser("模型已声明结束，但尚无匹配的实际执行依据，请先核对结果；任务没有记为已完成。")
    }
    private static func requiredOperations(_ text: String) -> Set<String> {
        var required = Set<String>()
        let operations = ["calendar_create", "calendar_search", "reminder_create", "reminder_search", "alarm_create", "alarm_list", "notes_create", "content_create", "health_query", "contact_search", "photo_search", "music_search", "music_play", "music_pause", "music_resume", "music_status", "location_current", "ctrip_query", "meituan_query", "meituan_paotui"]
        for clause in clauses(text) where !negated(clause) {
            for operation in operations where clause.contains(operation) { required.insert(operation) }
            let read = readIntent(clause)
            let create = !read && ["创建", "新建", "添加", "设置", "设一个", "设定", "安排", "保存", "写入", "create", "add ", "schedule", "set ", "save"].contains(where: clause.contains)
            if ["提醒", "reminder"].contains(where: clause.contains) {
                if create || clause.contains("提醒我") || clause.contains("remind me") { required.insert("reminder_create") }
                else if read { required.insert("reminder_search") }
            }
            if ["日历", "日程", "calendar", "event"].contains(where: clause.contains) {
                if create { required.insert("calendar_create") } else if read { required.insert("calendar_search") }
            }
            if ["闹钟", "alarm"].contains(where: clause.contains) {
                if create { required.insert("alarm_create") } else if read { required.insert("alarm_list") }
            }
            if ["备忘录", "apple notes"].contains(where: clause.contains), create { required.insert("notes_create") }
            if ["本机内容", "本机正文", "sela文件", "sela 文件", "local content"].contains(where: clause.contains), create { required.insert("content_create") }
            if ["步数", "睡眠", "运动记录", "health", "steps", "sleep", "workout"].contains(where: clause.contains), read { required.insert("health_query") }
            if ["联系人", "通讯录", "contact"].contains(where: clause.contains), read { required.insert("contact_search") }
            if ["照片", "相册", "photo"].contains(where: clause.contains), read { required.insert("photo_search") }
            if ["位置", "定位", "location"].contains(where: clause.contains), read || clause.contains("获取") { required.insert("location_current") }
            if ["音乐", "歌曲", "music", "song"].contains(where: clause.contains) {
                if read && ["状态", "播放状态", "status", "playing now"].contains(where: clause.contains) { required.insert("music_status") }
                else if read { required.insert("music_search") }
                else if ["暂停", "pause"].contains(where: clause.contains) { required.insert("music_pause") }
                else if ["继续", "恢复", "resume"].contains(where: clause.contains) { required.insert("music_resume") }
                else if ["播放", "play"].contains(where: clause.contains) { required.insert("music_play") }
            }
        }
        return required
    }
    private static func operationLabel(_ operation: String) -> String {
        let labels = ["calendar_create": "添加日程", "calendar_search": "查找日程", "reminder_create": "添加提醒", "reminder_search": "查找提醒", "alarm_create": "设置闹钟", "alarm_list": "查看闹钟", "notes_create": "创建备忘录", "content_create": "保存本机正文", "health_query": "读取健康数据", "contact_search": "查找联系人", "photo_search": "查找照片资料", "music_search": "查找音乐", "music_play": "播放音乐", "music_pause": "暂停音乐", "music_resume": "继续播放", "music_status": "查看播放状态", "location_current": "获取当前位置", "ctrip_query": "查询携程", "meituan_query": "查询美团旅行", "meituan_paotui": "查询跑腿服务"]
        return labels[operation] ?? "核对所需操作"
    }
    private static func requiresVisualMutation(_ text: String) -> Bool {
        clauses(text).contains { clause in
            !negated(clause) && !readIntent(clause) &&
            ["发送", "发给", "发微信", "点赞", "评论", "删除", "转账", "付款", "购买", "下单", "send ", "delete ", "purchase", "pay ", "comment ", "like "].contains(where: clause.contains)
        }
    }
    private static func clauses(_ text: String) -> [String] {
        var segmented = text
        for separator in ["并且", "然后", "随后", "接着", "同时", "之后", "而是", "改为", "改成", "并", "再", "只", " and then ", " then ", " and "] {
            segmented = segmented.replacingOccurrences(of: separator, with: ";")
        }
        segmented = segmented.replacingOccurrences(of: "改查", with: ";查询")
        return segmented.components(separatedBy: CharacterSet(charactersIn: "，。；;\n")).filter { !$0.isEmpty }
    }
    private static func negated(_ clause: String) -> Bool {
        ["不要", "无需", "不需要", "不用", "别发送", "取消", "don't ", "do not ", "no need to "].contains(where: clause.contains)
    }
    private static func readIntent(_ clause: String) -> Bool {
        func first(_ words: [String]) -> String.Index? {
            words.compactMap { clause.range(of: $0)?.lowerBound }.min()
        }
        let reads = first(["查询", "查找", "查看", "查一下", "查下", "看看", "读取", "列出", "有哪些", "多少", "告诉我", "总结", "识别", "观察", "search", "list", "read", "show", "check", "find", "inspect", "describe", "summarize", "what is", "what's"])
        guard let reads else { return false }
        let writes = first(["创建", "新建", "添加", "设置", "设定", "安排", "保存", "写入", "发送", "发给", "点赞", "评论", "删除", "购买", "下单", "播放", "暂停", "恢复", "create", "add ", "schedule", "set ", "save", "send ", "delete ", "purchase", "play", "pause", "resume"])
        return writes.map { reads < $0 } ?? true
    }
    private static func effectiveIntentText(_ goal: String) -> String {
        // This delimiter is host-generated by PhoneTaskRecord.effectiveGoal;
        // the task digest still binds every original/amended byte. A latest
        // explicit change of operation must not require the abandoned action.
        guard let marker = goal.range(of: "\n\n用户后续补充（与前文冲突时，以较新的明确要求为准）：\n") else { return goal }
        var current = String(goal[..<marker.lowerBound])
        for line in goal[marker.upperBound...].components(separatedBy: .newlines) {
            let addition = line.replacingOccurrences(of: "^[0-9]+\\. ", with: "", options: .regularExpression)
            let replacement = ["改为", "改成", "改查", "改做", "不要", "不用", "取消之前", "instead"].contains(where: addition.contains)
            if replacement && (!requiredOperations(addition).isEmpty || clauses(addition).contains(where: { !negated($0) && readIntent($0) }) || requiresVisualMutation(addition)) {
                current = addition
            } else { current += "\n" + addition }
        }
        return current
    }
}

/// Conversation-owned display evidence. It contains no goal, logs, checkpoint,
/// tool permissions or execution token, and cannot be resumed as a task.
struct NativeTaskSnapshot: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case completed, failed, stopped, interrupted, paused, needsUser
        var label: String {
            switch self {
            case .completed: return "已完成"
            case .failed: return "执行中断"
            case .stopped: return "已停止"
            case .interrupted: return "上次未结束"
            case .paused: return "已暂停"
            case .needsUser: return "需要处理"
            }
        }
    }
    let taskID: UUID
    let title: String
    let summary: String
    let state: State
    let updatedAt: Date
    let results: [NativeTaskResult]

    init?(taskID: UUID, title: String, summary: String, outcome: String, updatedAt: Date, results: [NativeTaskResult]) {
        guard let state = State(rawValue: outcome) else { return nil }
        self.taskID = taskID; self.title = title; self.summary = summary
        self.state = state; self.updatedAt = updatedAt; self.results = results
        guard valid else { return nil }
    }

    var valid: Bool {
        !title.isEmpty && title.count <= 160 && summary.count <= 60_000 && updatedAt.timeIntervalSince1970.isFinite &&
        !results.isEmpty && results.count <= 40 && Set(results.map(\.id)).count == results.count &&
        results.allSatisfy { result in
            !result.id.isEmpty && result.id.count <= 4096 && result.operation.count <= 80 &&
            result.title.count <= 160 && result.value.count <= 240 && result.detail.count <= 400 && result.notice.count <= 400 &&
            result.slot.count <= 200 && (result.systemObjectID?.utf8.count ?? 0) <= 4096 &&
            (result.collectionID?.utf8.count ?? 0) <= 4096 &&
            (result.date?.timeIntervalSince1970.isFinite ?? true) && (result.endDate?.timeIntervalSince1970.isFinite ?? true)
        }
    }
}
