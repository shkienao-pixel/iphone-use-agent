import Foundation

enum MemoryKind: String { case note = "笔记", preference = "偏好" }
struct AssistantMemory {
    var id = UUID()
    var title: String
    var text: String
    var kind: MemoryKind = .note
    var source = "手动记录"
    var createdAt = Date()
    var updatedAt = Date()
    var enabled = true
}
@main struct HomeChecks {
    @MainActor static func main() throws {
        let bundle = Bundle(path: CommandLine.arguments[1])!
        let home = SelaHomeContext(bundle: bundle)
        let formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-10-24T04:00:00Z")!
        var preference = AssistantMemory(title: "饮食偏好", text: "我喜欢清淡，不吃香菜", kind: .preference)
        home.update(records: [preference], enabled: true)
        precondition(home.suggestions.count == 3, "Missing bundled 30-task catalog")
        precondition(Set(home.suggestions.map(\.appId)).count == 3, "Duplicate apps")
        precondition(home.suggestions.contains { $0.prompt.contains(preference.text) }, "Preferences not attached to relevant task")
        precondition(home.greeting(at: now).contains(preference.text), "Greeting lost enabled preference")
        let previous = Set(home.suggestions.map(\.id)); home.refresh()
        precondition(previous.isDisjoint(with: Set(home.suggestions.map(\.id))), "Refresh repeats previous group")
        preference.enabled = false
        home.update(records: [preference], enabled: true)
        precondition(!home.greeting(at: now).contains(preference.text), "Disabled preference leaked")
        var event = AssistantMemory(title: "今天安排", text: "明天去机场", createdAt: formatter.date(from: "2026-10-23T04:00:00Z")!)
        home.update(records: [event], enabled: true)
        precondition(home.greeting(at: now).contains("昨天记下的「明天去机场」"), "Relative date lost provenance")
        event.text = "明天去机场，已经取消"
        home.update(records: [event], enabled: true)
        precondition(!home.greeting(at: now).contains("去机场"), "Cancelled plan included")
        home.update(records: [preference, event], enabled: false)
        precondition(home.suggestions.allSatisfy { $0.memoryDetail?.isEmpty != false }, "Memory-off task leaked preferences")
        print("PASS: 10 native home catalog, memory, date and refresh checks")
    }
}
