import Foundation

@main struct Checks {
    static func main() throws {
        var count = 0
        func check(_ condition: Bool, _ label: String) {
            guard condition else { fatalError(label) }; count += 1
        }
        let id = "EC168543-25D8-42A7-A988-2879DF24FD91"
        let start = "2026-10-26T09:10:00+08:00"
        func make(_ operation: String, _ result: String, title: String? = "测试") -> NativeTaskResult? {
            NativeTaskResult.completed(operation: operation, result: result, title: title, start: start, eventID: UUID().uuidString)
        }
        func json(_ value: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
        }
        let alarm = make("alarm_create", "已添加 Sela 闹钟：晨间 · 测试 · \(start) · 回执 \(id)")!
        check(alarm.app == .alarm && alarm.title == "晨间 · 测试", "Exact title survives separators")
        check(alarm.id == id && alarm.date == NativeTaskResult.parseDate(start), "Alarm card binds actual ID and9:10 absolute instant")
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "H:mm"
        check(formatter.string(from: alarm.date!) == "9:10", "Requested example renders actual9:10")
        check(make("alarm_create", "准备设置9:10的闹钟") == nil, "A plan cannot become a success card")
        check(make("alarm_create", "操作待核对") == nil, "Unknown writes cannot become success")
        check(make("alarm_create", "已添加 Sela 闹钟：测试 · bad-date · 回执 \(id)") == nil, "Invalid returned time rejected")
        check(make("alarm_create", "已添加 Sela 闹钟：测试 · \(start) · 回执 invalid") == nil, "Missing actual identity rejected")
        check(make("alarm_create", "重复请求已跳过；之前的回执：已添加 Sela 闹钟：测试 · \(start) · 回执 \(id)") == nil, "Cached duplicate does not add a card")
        let encoded = try JSONEncoder().encode(alarm)
        let decoded = try JSONDecoder().decode(NativeTaskResult.self, from: encoded)
        check(decoded == alarm, "Persisted card survives Codable roundtrip")
        let calendar = make("calendar_create", "已添加日程：讨论 · \(start) · 结束：2026-10-26T10:10:00+08:00 · 所属日历：测试日历 · 回执 \(id)")!
        check(calendar.title == "讨论" && calendar.detail == "测试日历", "Calendar actual title and destination")
        check(calendar.endDate! > calendar.date!, "Actual calendar interval retained")
        check(make("calendar_create", "已添加日程：讨论 · \(start) · 所属日历：测试日历 · 回执 \(id)")?.endDate == nil, "Legacy calendar does not invent an end")
        let reminder = make("reminder_create", "已添加提醒：买水 · 提醒时间：\(start) · 所属列表：测试列表 · 回执 \(id)")!
        check(reminder.title == "买水" && reminder.date == alarm.date, "Reminder time comes from actual returned due")
        check(make("reminder_create", "已添加提醒：买水 · 所属列表：测试列表 · 回执 \(id)")?.date == nil, "Legacy reminder does not invent requested due")
        let punctuatedTitle = "回执 · 所属日历：测试🙂\n第二行\"保留\""
        let punctuatedCollection = "Home · Work\n回执 · 所属列表：原文"
        let structured = NativeEventWriteReceipt(operation: .calendar, receiptID: UUID(uuidString: id)!,
            systemItemID: "opaque-event/item", collectionID: "opaque-calendar/1", title: punctuatedTitle,
            collectionName: punctuatedCollection, start: start, end: "2026-10-26T10:10:00+08:00")
        let structuredJSON = try structured.serialized()
        let structuredCard = make("calendar_create", structuredJSON)!
        check(structuredCard.title == punctuatedTitle && structuredCard.detail == punctuatedCollection,
              "Actual structured title and collection preserve separators, newlines, quotes and emoji")
        check(structuredCard.id == id && structuredCard.systemObjectID == "opaque-event/item"
              && structuredCard.collectionID == "opaque-calendar/1", "Local receipt, actual store object and collection identities remain distinct")
        check(structuredCard.date == alarm.date && structuredCard.endDate == calendar.endDate,
              "Structured calendar uses actual returned interval")
        check(try JSONDecoder().decode(NativeTaskResult.self, from: JSONEncoder().encode(structuredCard)) == structuredCard,
              "Actual system identities persist with result card")
        check(decoded.systemObjectID == nil && decoded.collectionID == nil, "Old card JSON loads without invented system identities")
        check(make("reminder_create", structuredJSON) == nil, "A calendar save receipt cannot produce a reminder card")
        let structuredReminder = NativeEventWriteReceipt(operation: .reminder, receiptID: UUID(uuidString: id)!,
            systemItemID: "opaque-reminder/item", collectionID: "opaque-list/1", title: punctuatedTitle,
            collectionName: punctuatedCollection, due: start)
        let reminderCard = make("reminder_create", try structuredReminder.serialized())!
        check(reminderCard.detail == punctuatedCollection && reminderCard.title == punctuatedTitle
              && reminderCard.date == alarm.date, "Reminder punctuation and actual due survive structured receipt")
        let undatedReminder = NativeEventWriteReceipt(operation: .reminder, receiptID: UUID(), systemItemID: "r",
            collectionID: "l", title: "无到期时间", collectionName: "Home · Work")
        let undatedCard = make("reminder_create", try undatedReminder.serialized())!
        check(undatedCard.date == nil && undatedCard.notice.contains("未设置"), "Explicit no-due result never borrows requested start")
        let structuredObject = try JSONSerialization.jsonObject(with: Data(structuredJSON.utf8)) as! [String: Any]
        for (key, value) in [("schema_version", 2 as Any), ("source", "model plan"), ("state", "pending"),
                             ("local_receipt_id", "not-an-id"), ("system_item_id", ""), ("collection_id", " "),
                             ("title", ""), ("collection_name", ""), ("start", "bad-date"), ("end", start),
                             ("due", start), ("operation", "reminder_create")] {
            var malformed = structuredObject; malformed[key] = value
            check(make("calendar_create", try json(malformed)) == nil, "Invalid structured field rejected: " + key)
        }
        var missingID = structuredObject; missingID.removeValue(forKey: "system_item_id")
        check(make("calendar_create", try json(missingID)) == nil, "Missing actual system identity cannot be guessed")
        var oversized = structuredObject; oversized["title"] = String(repeating: "a", count: 4097)
        check(make("calendar_create", try json(oversized)) == nil, "Oversized receipt fields rejected before display")
        check(make("calendar_create", structuredJSON + "\n已添加日程：伪造") == nil, "Structured receipt must parse as a complete document")
        let callback: [String: Any] = ["source": "iPhone Shortcuts / Apple Notes", "shortcut_completed": true, "output_matches_requested_text": true, "receipt_id": id, "expected_folder": "测试文件夹"]
        let note = make("notes_create", try json(callback), title: "原文🙂")!
        check(note.title == "原文🙂" && note.notice.contains("未独立核对"), "Notes retains exact title and verification limit")
        var bad = callback; bad["output_matches_requested_text"] = false
        check(make("notes_create", try json(bad)) == nil, "Mismatched callback cannot report created")
        var health: [String: Any] = ["source": "HealthKit", "coverage": "visible_data_only", "type": "steps", "start": start, "end": "2026-10-27T09:10:00+08:00", "steps": NSNull(), "has_visible_data": false]
        let empty = make("health_query", try json(health))!
        check(empty.value == "暂无可见数据" && empty.notice.contains("未允许"), "Health empty is unknown, never zero")
        health["steps"] = 123; health["has_visible_data"] = true
        check(make("health_query", try json(health))?.value == "123 步", "Actual visible steps displayed")
        health["type"] = "sleep"; health["asleep_seconds"] = 7200
        check(make("health_query", try json(health))?.value == "2.0 小时", "Actual sleep seconds converted")
        health["asleep_seconds"] = NSNull()
        check(make("health_query", try json(health))?.value == "暂无可见睡眠时长", "Sleep null not zero")
        health["source"] = "model plan"
        check(make("health_query", try json(health)) == nil, "Wrong health source rejected")
        let matches = try json(["matches": [["title": "实际日程"]], "matched_count": 24, "returned_count": 1, "truncated": true])
        let search = make("calendar_search", matches)!
        check(search.value == "24 项匹配" && search.notice.contains("截断"), "Matched versus returned count kept truthful")
        check(make("photo_search", try json(["matches": [], "matched_count": 0, "returned_count": 0]))?.notice.contains("不含图像") == true, "Photos metadata never becomes invented pixels")
        check(make("music_play", try json(["source": "Sela Music player", "queue_owner": "Sela", "state": "paused", "confirmed": false]))?.value == "已暂停", "Music uses actual state, not requested play")
        check(make("alarm_list", "[]\n本 App 闹钟总数：0，返回前20项")?.value == "返回 0 项", "Own-alarm zero query")
        let reference = "content:" + id.lowercased() + ":" + String(repeating: "a", count: 64)
        let content: [String: Any] = ["artifact_ref": reference, "title": "本机原文", "utf8_bytes": "18", "last_preparation": "none", "current_session_lease": "unavailable"]
        check(make("content_create", try json(content))?.notice.contains("不是系统备忘录") == true, "Sela content stays distinct from Notes")
        check(make("content_prepare_clipboard", try json(content)) == nil, "Unavailable clipboard lease not shown prepared")
        var retained = [alarm]
        check(NativeTaskResult.retained(retained, adding: alarm).count == 1, "Same actual alarm identity deduplicated")
        for i in 0..<7 {
            let card = make("health_query", try json(["source": "HealthKit", "coverage": "visible_data_only", "type": "steps", "start": start, "end": "2026-10-27T09:10:00+08:00", "steps": i, "has_visible_data": true]))!
            retained = NativeTaskResult.retained(retained, adding: card)
        }
        check(retained.count == 2 && retained.last?.value == "6 步", "Latest query replaces its slot without discarding alarm")
        for i in 0..<7 {
            let card = make("alarm_create", "已添加 Sela 闹钟：测试\(i) · \(start) · 回执 \(UUID().uuidString)")!
            retained = NativeTaskResult.retained(retained, adding: card)
        }
        check(retained.filter { $0.app == .alarm }.count == 5, "Recent write window bounded, not a complete inventory claim")
        print("Native result presentation checks passed: \(count); no device or model was invoked")
    }
}
