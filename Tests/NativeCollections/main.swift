import Foundation

typealias Target = NativeCollectionTarget.Descriptor
var checks = 0
func expect(_ condition: Bool) { precondition(condition); checks += 1 }
func rejects(_ block: () throws -> Void) {
    do { try block(); fatalError("Unsafe target/parameters accepted") }
    catch is AgentError { checks += 1 }
    catch { fatalError("Unexpected error: \(error)") }
}
let personal = Target(id: "personal", title: "个人", writable: true)
let test = Target(id: "test", title: "Sela测试", writable: true)
let holidays = Target(id: "holidays", title: "假日", writable: false)
let available = [personal, test, holidays]
let explicit = try NativeCollectionTarget.select(available, named: "Sela测试", defaultID: "personal", label: "日历")
expect(explicit == test) // The known OS default must not override an explicit destination.
expect(try NativeCollectionTarget.select(available, named: nil, defaultID: "personal", label: "日历") == personal)
expect(try NativeCollectionTarget.select(available, named: " Sela测试\n", defaultID: nil, label: "日历") == test)
rejects { _ = try NativeCollectionTarget.select(available, named: "不存在", defaultID: "personal", label: "日历") }
rejects { _ = try NativeCollectionTarget.select(available, named: " ", defaultID: "personal", label: "日历") }
rejects { _ = try NativeCollectionTarget.select(available, named: "假日", defaultID: "personal", label: "日历") }
rejects { _ = try NativeCollectionTarget.select(available, named: nil, defaultID: "holidays", label: "日历") }
rejects { _ = try NativeCollectionTarget.select(available, named: nil, defaultID: nil, label: "日历") }
rejects { _ = try NativeCollectionTarget.select(available, named: nil, defaultID: "deleted", label: "日历") }
let duplicate = Target(id: "other-account", title: "Sela测试", writable: true)
rejects { _ = try NativeCollectionTarget.select(available + [duplicate], named: "Sela测试", defaultID: "test", label: "日历") }
let unicode = Target(id: "unicode", title: "Caf\u{e9}", writable: true)
expect(try NativeCollectionTarget.select([unicode], named: "Cafe\u{301}", defaultID: nil, label: "列表") == unicode)
rejects { _ = try NativeCollectionTarget.select([unicode, Target(id: "duplicate", title: "Cafe\u{301}", writable: false)], named: "Caf\u{e9}", defaultID: nil, label: "列表") }

let calendarJSON = #"{"operation":"calendar_create","title":"测试","start":"2026-10-25T14:00:00+08:00","end":"2026-10-25T14:15:00+08:00","calendar_name":"Sela测试"}"#
let calendar = try SystemToolRequest.decode(calendarJSON)
expect(calendar.calendar_name == "Sela测试")
expect(calendar.preview.contains("目标日历：Sela测试"))
let reminder = try SystemToolRequest.decode(#"{"operation":"reminder_create","title":"测试","list_name":"Sela测试"}"#)
expect(reminder.list_name == "Sela测试")
expect(reminder.preview.contains("目标列表：Sela测试"))
for invalid in [
    calendarJSON.replacingOccurrences(of: "calendar_name", with: "list_name"),
    calendarJSON.replacingOccurrences(of: "calendar_create", with: "calendar_search"),
    calendarJSON.replacingOccurrences(of: "Sela测试", with: ""),
    calendarJSON.replacingOccurrences(of: "Sela测试", with: String(repeating: "x", count: 161)),
    #"{"operation":"reminder_search","query":"测试","list_name":"Sela测试"}"#,
    #"{"operation":"reminder_create","title":"测试","calendar_id":"invented"}"#
] { rejects { _ = try SystemToolRequest.decode(invalid) } }
let legacy = try SystemToolRequest.decode(#"{"operation":"reminder_create","title":"测试"}"#)
let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
expect(object["calendar_name"] == nil && object["list_name"] == nil)
expect(legacy.calendar_name == nil && legacy.list_name == nil)
print("\(checks) native collection selection and wire-contract checks passed. Offline snapshots only; no EventKit/device writes.")
