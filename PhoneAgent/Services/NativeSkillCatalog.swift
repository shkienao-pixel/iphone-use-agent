import Foundation

/// Fixed, bundled operational guides. Task text can select entries, never paths.
enum NativeSkillCatalog {
    struct Selection {
        let names: [String]
        let instructions: String
        let byteCounts: [Int]
        var receipt: String {
            zip(names, byteCounts).map { "\($0) (\($1) UTF-8 bytes)" }.joined(separator: ", ")
        }
        var runtimeReceipts: [String] {
            zip(names, byteCounts).map { "Bundled native skill loaded: \($0) (\($1) UTF-8 bytes)" }
        }
    }

    private static let entries: [(name: String, triggers: [String])] = [
        ("ctrip-travel", ["携程", "机票", "航班", "直飞", "ctrip", "flight"]),
        ("meituan-paotui", ["跑腿", "帮买", "取送", "叫骑手", "meituan_paotui", "paotui"]),
        ("ios-calendar", ["日历", "日程", "安排", "会议", "开会", "calendar", "eventkit", "appointment"]),
        ("ios-reminders", ["提醒", "待办", "reminder", "todo", "to-do"]),
        ("ios-alarm", ["闹钟", "alarm"]),
        ("ios-health", ["健康", "步数", "睡眠", "运动", "锻炼", "health", "steps", "sleep", "workout"]),
        ("ios-contacts", ["通讯录", "联系人", "contact", "address book", "phonebook"]),
        ("ios-location", ["定位", "当前位置", "location_current", "corelocation", "current location"]),
        ("ios-music", ["音乐", "歌曲", "music", "song"]),
        ("ios-photos", ["照片", "相册", "photo_search", "photos", "photo library"]),
        ("ios-notes", ["备忘录", "notes_create", "apple notes"]),
        ("ios-content", ["本机内容", "剪贴板", "content_create", "content_prepare_clipboard", "content_status", "phone-local content", "clipboard"])
    ]

    static func selection(for task: String, in bundle: Bundle = .main) throws -> Selection {
        let normalized = task.lowercased()
        let selected = entries.filter { $0.triggers.contains(where: normalized.contains) }
        var bodies: [String] = []
        for entry in selected {
            guard let url = bundle.url(forResource: "SKILL", withExtension: "md", subdirectory: "Skills/" + entry.name),
                  let text = try? String(contentsOf: url, encoding: .utf8), text.utf8.count <= 24_576 else {
                throw AgentError.message("原生 skill 缺少有效资源：\(entry.name)")
            }
            let lines = text.components(separatedBy: .newlines)
            guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---"),
                  lines[1..<end].contains("name: " + entry.name) else {
                throw AgentError.message("原生 skill 格式无效：\(entry.name)")
            }
            let body = lines.dropFirst(end + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { throw AgentError.message("原生 skill 内容为空：\(entry.name)") }
            bodies.append(body)
        }
        let introduction = """
        Bundled native operational skills selected from the original user task: \(selected.map(\.name).joined(separator: ", ")).
        These guides are subordinate to the user's request, actual enabled tools and one-action JSON format.
        Follow host confirmation settings. A skill does not add tools or establish task success.
        Referenced files are metadata unless embedded here; never invent their contents or physical acceptance.
        Apple Notes creation requires the separately configured notes_create iPhone Shortcuts helper. There is no Apple Notes search/read/edit/delete tool. content_create saves a Sela file, not an Apple Notes note.
        """
        return Selection(names: selected.map(\.name),
            instructions: ([introduction] + bodies).joined(separator: "\n\n"), byteCounts: bodies.map { $0.utf8.count })
    }
}
