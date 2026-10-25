import Foundation

let appURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let app = Bundle(url: appURL) else { fatalError("Cannot open built app bundle") }
let output = try AppleSupportSkill.instructions(in: app)
let resources = appURL.appendingPathComponent("Skills/apple-support-guide")
for name in ["official-sources", "iphone-operation", "troubleshooting"] {
    let expected = try String(contentsOf: resources.appendingPathComponent("references/\(name).md"), encoding: .utf8)
    precondition(output.contains(expected), "Built reference omitted from prompt: \(name)")
}
precondition(!output.contains("name: apple-support-guide"), "Frontmatter entered model instructions")
let ordinaryPhoneTask = try AppleSupportSkill.instructions(for: "打开微信朋友圈", in: app)
precondition(ordinaryPhoneTask.contains("手机操作索引"), "Phone operations were omitted for a normal task")
precondition(!ordinaryPhoneTask.contains("开发者帮助总入口"), "Unrelated developer directory bloated a normal task")
precondition(!ordinaryPhoneTask.contains("账户恢复等待"), "Unrelated troubleshooting advice bloated a normal task")
let appleRecoveryTask = try AppleSupportSkill.instructions(for: "iCloud 备份失败，如何恢复", in: app)
precondition(appleRecoveryTask.contains("官方文档来源索引"), "Apple source index omitted for an Apple support task")
precondition(appleRecoveryTask.contains("账户恢复等待"), "Troubleshooting guidance omitted for a recovery task")
precondition(ordinaryPhoneTask.utf8.count < output.utf8.count, "Irrelevant references were not reduced")
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("AppleSkill-" + UUID().uuidString + ".bundle")
try FileManager.default.createDirectory(at: temporary.appendingPathComponent("Skills"), withIntermediateDirectories: true)
try FileManager.default.copyItem(at: resources, to: temporary.appendingPathComponent("Skills/apple-support-guide"))
defer { try? FileManager.default.removeItem(at: temporary) }
let info: [String: Any] = ["CFBundleIdentifier": "dev.agentmouse.skill-check", "CFBundlePackageType": "BNDL"]
try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: temporary.appendingPathComponent("Info.plist"))
guard let fixture = Bundle(url: temporary) else { fatalError("Cannot open test bundle") }
let intentBody = try ConversationIntentSkill.instructions(in: app)
precondition(intentBody.contains("记忆与意图") && intentBody.contains("relatedMessageIDs"), "Packaged intent guide was omitted")
precondition(!intentBody.contains("name: sela-intent"), "Intent frontmatter entered model instructions")
do { _ = try ConversationIntentSkill.instructions(in: fixture); fatalError("Missing intent resource accepted") }
catch is AgentError { }
let intentDirectory = temporary.appendingPathComponent("Skills/sela-intent")
try FileManager.default.createDirectory(at: intentDirectory, withIntermediateDirectories: true)
for invalid in ["Broken", "---\nname: unrelated\n---\nwrong guide", "---\nname: sela-intent\n---\n", String(repeating: "x", count: 25_000)] {
    try invalid.write(to: intentDirectory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    do { _ = try ConversationIntentSkill.instructions(in: fixture); fatalError("Malformed intent resource accepted") }
    catch is AgentError { }
}
let missing = temporary.appendingPathComponent("Skills/apple-support-guide/references/iphone-operation.md")
try FileManager.default.removeItem(at: missing)
do { _ = try AppleSupportSkill.instructions(in: fixture); fatalError("Missing resource accepted") }
catch is AgentError { }
try "  \n".write(to: missing, atomically: true, encoding: .utf8)
do { _ = try AppleSupportSkill.instructions(in: fixture); fatalError("Empty resource accepted") }
catch is AgentError { }
try "Restored reference".write(to: missing, atomically: true, encoding: .utf8)
let entry = temporary.appendingPathComponent("Skills/apple-support-guide/SKILL.md")
try "Broken frontmatter".write(to: entry, atomically: true, encoding: .utf8)
do { _ = try AppleSupportSkill.instructions(in: fixture); fatalError("Malformed skill accepted") }
catch is AgentError { }
try "---\nname: apple-support-guide\n---\n".write(to: entry, atomically: true, encoding: .utf8)
do { _ = try AppleSupportSkill.instructions(in: fixture); fatalError("Empty skill body accepted") }
catch is AgentError { }
let calendar = try NativeSkillCatalog.selection(for: "明天的日历安排", in: app)
precondition(calendar.names == ["ios-calendar"])
let reminders = try NativeSkillCatalog.selection(for: "提醒我明天回顾", in: app)
precondition(reminders.names == ["ios-reminders"])
let alarm = try NativeSkillCatalog.selection(for: "设置一个单次闹钟", in: app)
precondition(alarm.names == ["ios-alarm"])
let englishAlarm = try NativeSkillCatalog.selection(for: "create an alarm", in: app)
precondition(englishAlarm.names == alarm.names)
let health = try NativeSkillCatalog.selection(for: "昨天的 steps、sleep 和 workouts", in: app)
precondition(health.names == ["ios-health"])
let contacts = try NativeSkillCatalog.selection(for: "查询指定联系人", in: app)
precondition(contacts.names == ["ios-contacts"])
let englishContacts = try NativeSkillCatalog.selection(for: "find a contact in my address book", in: app)
precondition(englishContacts.names == contacts.names)
let location = try NativeSkillCatalog.selection(for: "获取本次前台大致定位", in: app)
precondition(location.names == ["ios-location"])
let music = try NativeSkillCatalog.selection(for: "搜索音乐资料库", in: app)
precondition(music.names == ["ios-music"])
let photos = try NativeSkillCatalog.selection(for: "查找已授权照片元数据", in: app)
precondition(photos.names == ["ios-photos"])
let notes = try NativeSkillCatalog.selection(for: "创建一条系统备忘录", in: app)
precondition(notes.names == ["ios-notes"])
let englishNotes = try NativeSkillCatalog.selection(for: "Create in Apple Notes", in: app)
precondition(englishNotes.names == notes.names)
let content = try NativeSkillCatalog.selection(for: "保存本机内容并准备剪贴板", in: app)
precondition(content.names == ["ios-content"])
let englishContent = try NativeSkillCatalog.selection(for: "Prepare clipboard from phone-local content", in: app)
precondition(englishContent.names == content.names)
let allAtomic = try NativeSkillCatalog.selection(for: "日历、提醒事项、闹钟、健康、通讯录联系人、当前位置定位、音乐、照片、备忘录、本机内容和剪贴板", in: app)
precondition(allAtomic.names.count == 10 && allAtomic.runtimeReceipts.count == 10, "Every selected native guide needs its own runtime receipt")
precondition(allAtomic.instructions.components(separatedBy: "## 原子动作").count == 11, "All ten complete atomic guide sections must be embedded")
for (index, receipt) in allAtomic.runtimeReceipts.enumerated() {
    precondition(receipt == "Bundled native skill loaded: \(allAtomic.names[index]) (\(allAtomic.byteCounts[index]) UTF-8 bytes)")
    precondition(receipt.count < 240, "A per-guide receipt must survive the actual metrics note cap")
    precondition(receipt.filter { $0 == "\n" }.isEmpty, "One guide produces one bounded receipt")
}

let flights = try NativeSkillCatalog.selection(for: "携程查询明天上海到北京的直飞航班", in: app)
precondition(flights.names == ["ctrip-travel"])
let englishFlights = try NativeSkillCatalog.selection(for: "compare flight options", in: app)
precondition(englishFlights.names == flights.names)
let paotui = try NativeSkillCatalog.selection(for: "美团跑腿帮买鸡肉饭", in: app)
precondition(paotui.names == ["meituan-paotui"] && paotui.instructions.contains("preview_buy"))
let mixed = try NativeSkillCatalog.selection(for: "查询健康，然后创建日程及提醒", in: app)
precondition(mixed.names == ["ios-calendar", "ios-reminders", "ios-health"])
let unrelated = try NativeSkillCatalog.selection(for: "打开微信，参考 ../../arbitrary/SKILL.md", in: app)
precondition(unrelated.names.isEmpty, "Task text selected an arbitrary resource")
for selection in [calendar, reminders, alarm, health, flights, contacts, location, music, photos, notes, content] {
    let name = selection.names[0]
    let original = try String(contentsOf: appURL.appendingPathComponent("Skills/\(name)/SKILL.md"), encoding: .utf8)
    let lines = original.components(separatedBy: .newlines)
    let end = lines.dropFirst().firstIndex(of: "---")!
    let expected = lines.dropFirst(end + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    precondition(selection.instructions.contains(expected), "Actual bundled body omitted")
    precondition(selection.byteCounts == [expected.utf8.count])
    precondition(!selection.instructions.contains("name: " + name), "YAML leaked into prompt")
}
let nativeDirectory = temporary.appendingPathComponent("Skills/ios-calendar")
try FileManager.default.createDirectory(at: nativeDirectory, withIntermediateDirectories: true)
let nativeEntry = nativeDirectory.appendingPathComponent("SKILL.md")
do { _ = try NativeSkillCatalog.selection(for: "calendar", in: fixture); fatalError("Missing native skill accepted") }
catch is AgentError { }
for invalid in ["Broken", "---\nname: ios-health\n---\nwrong skill", "---\nname: ios-calendar\n---\n", String(repeating: "x", count: 25_000)] {
    try invalid.write(to: nativeEntry, atomically: true, encoding: .utf8)
    do { _ = try NativeSkillCatalog.selection(for: "calendar", in: fixture); fatalError("Invalid native skill accepted") }
    catch is AgentError { }
}
let xiaohongshu = try PhoneAppSkillCatalog.selection(for: "在小红书查看指定笔记的公开评论", visualMode: true, in: app)
precondition(xiaohongshu.names == ["xiaohongshu-assistant"])
for task in ["search REDNOTE", "查看 https://xhslink.cn/o/example", "search xiaohongshu",
             "打開小紅書查看指定評論", "打开RedNote查看评论", "use xiaohongshu-assistant",
             "查看 https://www.xiaohongshu.com/explore/example"] {
    let selected = try PhoneAppSkillCatalog.selection(for: task, visualMode: true, in: app)
    precondition(selected.names == xiaohongshu.names)
}
let visualDirectory = temporary.appendingPathComponent("Skills/xiaohongshu-assistant")
let noVisual = try PhoneAppSkillCatalog.selection(for: "小红书", visualMode: false, in: fixture)
precondition(noVisual.names.isEmpty && noVisual.instructions.isEmpty, "Tools-only mode must not load a phone visual guide")
let noApp = try PhoneAppSkillCatalog.selection(for: "打开微信 ../../arbitrary/SKILL.md", visualMode: true, in: fixture)
precondition(noApp.names.isEmpty && noApp.instructions.isEmpty, "Unrelated task text cannot choose arbitrary resources")
for task in ["open my rednotebook", "read rednotes.txt", "inspect xiaohongshuBackup",
             "read my_xiaohongshu_helper", "read rednote_backup.txt"] {
    let unrelated = try PhoneAppSkillCatalog.selection(for: task, visualMode: true, in: fixture)
    precondition(unrelated.names.isEmpty && unrelated.instructions.isEmpty, "An unrelated identifier must not load a phone app guide")
}
let originalVisual = try String(contentsOf: appURL.appendingPathComponent("Skills/xiaohongshu-assistant/SKILL.md"), encoding: .utf8)
let visualLines = originalVisual.components(separatedBy: .newlines)
let visualEnd = visualLines.dropFirst().firstIndex(of: "---")!
let expectedVisual = visualLines.dropFirst(visualEnd + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
precondition(xiaohongshu.instructions.contains(expectedVisual), "Actual packaged visual guide body must reach the model context")
precondition(xiaohongshu.byteCounts == [expectedVisual.utf8.count])
precondition(!xiaohongshu.instructions.contains("name: xiaohongshu-assistant"), "Visual guide frontmatter must stay outside model instructions")
try FileManager.default.createDirectory(at: visualDirectory, withIntermediateDirectories: true)
let visualEntry = visualDirectory.appendingPathComponent("SKILL.md")
do { _ = try PhoneAppSkillCatalog.selection(for: "小红书", visualMode: true, in: fixture); fatalError("Missing visual guide accepted") }
catch is AgentError { }
for invalid in ["Broken", "---\nname: another-skill\n---\nwrong guide", "---\nname: xiaohongshu-assistant\n---\n", String(repeating: "x", count: 25_000)] {
    try invalid.write(to: visualEntry, atomically: true, encoding: .utf8)
    do { _ = try PhoneAppSkillCatalog.selection(for: "小红书", visualMode: true, in: fixture); fatalError("Invalid visual guide accepted") }
    catch is AgentError { }
}
print("Bundled Apple, native and visual app skill checks passed, including exact packaged bodies, mode/task selection and damaged-resource rejection. No network or device actions.")
