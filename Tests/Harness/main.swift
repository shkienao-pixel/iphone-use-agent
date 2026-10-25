import Foundation

var checks = 0

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError("Harness check failed: \(message)") }
    checks += 1
}

func rejects(_ message: String, _ operation: () throws -> Void) {
    do {
        try operation()
        fatalError("Harness accepted invalid input: \(message)")
    } catch {
        checks += 1
    }
}

func request(_ text: String) throws -> PhoneHarnessRequest {
    try PhoneHarnessRequest.decode(text)
}

// Requests express semantic actions. Unknown operations or surplus parameters must
// fail before a request can turn into an accessory command.
for (json, expected) in [
    (#"{"operation":"tap","target":"search.field"}"#, "tap"),
    (#"{"operation":"open_search"}"#, "open_search"),
    (#"{"operation":"open_app","target":"设置"}"#, "open_app"),
    (#"{"operation":"back"}"#, "back"),
    (#"{"operation":"home"}"#, "home"),
    (#"{"operation":"type_text","text":"Settings 123!?\n"}"#, "type_text"),
    (#"{"operation":"press_key","target":"ENTER"}"#, "press_key")
] {
    let value = try request(json)
    check(value.operation.rawValue == expected, "decode \(expected)")
}
let optionalFields = try request(#"{"operation":"home","target":null,"text":null}"#)
check(optionalFields.operation == .home, "unused null fields are accepted")
let savedID = UUID().uuidString
for op in [PhoneHarnessRequest.Operation.xhs_collect, .chat_read, .chat_read_newer, .chat_summarize, .file_status, .file_send] {
    let value = PhoneHarnessRequest(operation: op, target: savedID, operationID: "saved-workflow-001")
    let decoded = try PhoneHarnessRequest.decode(String(decoding: JSONEncoder().encode(value), as: UTF8.self))
    check(decoded == value, "saved workflow survives strict outer envelope")
    rejects("saved workflow cannot invent a named scope") {
        try PhoneHarnessRequest(operation: op, target: "unapproved chat", operationID: "saved-workflow-001").validate()
    }
    rejects("saved workflow cannot widen scope with text") {
        try PhoneHarnessRequest(operation: op, target: savedID, text: "read all", operationID: "saved-workflow-001").validate()
    }
    rejects("saved workflow requires stable operation ID") {
        try PhoneHarnessRequest(operation: op, target: savedID).validate()
    }
    rejects("saved workflow rejects control characters in operation ID") {
        try PhoneHarnessRequest(operation: op, target: savedID, operationID: "workflow\n001").validate()
    }
}
let ascii = String((32...126).compactMap(UnicodeScalar.init).map(Character.init)) + "\t\n\r"
try PhoneHarnessRequest(operation: .type_text, text: ascii).validate()
check(true, "all supported ASCII characters survive validation")
let limitText = String(repeating: "a", count: 500)
try PhoneHarnessRequest(operation: .type_text, text: limitText).validate()
check(true, "500-character HID input is accepted")

for (name, json) in [
    ("unknown operation", #"{"operation":"send_message","target":"someone"}"#),
    ("unknown key", #"{"operation":"tap","target":"search.field","x":0.4}"#),
    ("array envelope", #"[{"operation":"home"}]"#),
    ("missing operation", #"{"target":"search.field"}"#),
    ("wrong target type", #"{"operation":"tap","target":3}"#),
    ("missing tap target", #"{"operation":"tap"}"#),
    ("blank tap target", #"{"operation":"tap","target":"  \n "}"#),
    ("missing app name", #"{"operation":"open_app"}"#),
    ("missing input", #"{"operation":"type_text"}"#),
    ("empty input", #"{"operation":"type_text","text":""}"#),
    ("Unicode input", #"{"operation":"type_text","text":"设置"}"#),
    ("emoji input", #"{"operation":"type_text","text":"hello 👋"}"#),
    ("unsupported control character", #"{"operation":"type_text","text":"\u0000"}"#),
    ("unsupported key", #"{"operation":"press_key","target":"PAY"}"#),
    ("irrelevant text", #"{"operation":"home","text":"unrelated"}"#),
    ("irrelevant target", #"{"operation":"back","target":"settings"}"#)
] {
    rejects(name) { _ = try request(json) }
}
rejects("nil request") { _ = try PhoneHarnessRequest.decode(nil) }
rejects("oversized input") { try PhoneHarnessRequest(operation: .type_text, text: limitText + "b").validate() }
rejects("oversized app name") { try PhoneHarnessRequest(operation: .open_app, target: String(repeating: "a", count: 81)).validate() }
rejects("oversized JSON envelope") { _ = try request(String(repeating: " ", count: 16000) + #"{"operation":"home"}"#) }
let action = try AgentAction.decodeResponse(#"{"kind":"phone_tool","text":"{\"operation\":\"open_search\"}","reason":"打开搜索"}"#)
check(action.kind == .phone_tool, "semantic tool survives the model action envelope")
rejects("invalid semantic request in model envelope") {
    _ = try AgentAction.decodeResponse(#"{"kind":"phone_tool","text":"{\"operation\":\"tap\"}","reason":"点击"}"#)
}

let rect = PhoneUIRect(x: 0.1, y: 0.2, width: 0.2, height: 0.1)
check(rect.valid, "normalized rectangle is valid")
check(abs(rect.centerX - 0.2) < 0.000001 && abs(rect.centerY - 0.25) < 0.000001,
      "tap point is the rectangle center")
check(PhoneUIRect(x: 0, y: 0, width: 1, height: 1).valid, "full-screen bounds are valid")
for (name, invalid) in [
    ("negative x", PhoneUIRect(x: -0.01, y: 0, width: 0.1, height: 0.1)),
    ("right overflow", PhoneUIRect(x: 0.95, y: 0, width: 0.1, height: 0.1)),
    ("bottom overflow", PhoneUIRect(x: 0, y: 0.95, width: 0.1, height: 0.1)),
    ("zero width", PhoneUIRect(x: 0, y: 0, width: 0, height: 0.1)),
    ("negative height", PhoneUIRect(x: 0, y: 0, width: 0.1, height: -0.1)),
    ("nonfinite origin", PhoneUIRect(x: .nan, y: 0, width: 0.1, height: 0.1)),
    ("nonfinite size", PhoneUIRect(x: 0, y: 0, width: .infinity, height: 0.1))
] {
    check(!invalid.valid, "reject \(name)")
}

let now = Date()
let search = PhoneUIElement(id: "home.search", label: "Search", rect: rect, source: "ocr")
let back = PhoneUIElement(id: "settings.back", label: "Settings", rect: rect, source: "ocr")
func snapshot(_ scene: String, elements: [PhoneUIElement] = [], device: String = "iphone-portrait-layout-a",
              at: Date = now, blocked: Bool = false) -> PhoneUISnapshot {
    PhoneUISnapshot(deviceKey: device, scene: scene, elements: elements, capturedAt: at, blockingOverlay: blocked)
}

let controls = snapshot("home", elements: [search])
check(controls.element(id: "home.search") == search, "ID resolves a current element")
check(controls.element(id: "missing") == nil, "unknown ID does not invent a location")
check(controls.matchingLabel("  search  ") == search, "label lookup normalizes case and outer whitespace")
check(controls.matchingLabel("Sea") == nil, "partial text does not match a label")
let duplicate = PhoneUIElement(id: "other.search", label: "SEARCH", rect: rect, source: "ocr")
let ambiguous = snapshot("home", elements: [search, duplicate])
check(ambiguous.matchingLabel("Search") == nil, "duplicate normalized labels are ambiguous")
let duplicateID = snapshot("home", elements: [search, PhoneUIElement(id: search.id, label: "Other", rect: rect, source: "ocr")])
check(duplicateID.element(id: search.id) == nil, "duplicate IDs cannot choose an arbitrary target")

func learnedSearch() throws -> PhoneLayoutMemory {
    var memory = PhoneLayoutMemory()
    try memory.record(name: "home.search", element: search,
                      source: snapshot("home", elements: [search], at: now.addingTimeInterval(-2)),
                      destination: snapshot("search", at: now.addingTimeInterval(-1)))
    return memory
}
let memory = try learnedSearch()
check(memory.control(named: "home.search", in: controls) != nil, "observed search transition creates usable memory")
check(memory.control(named: "home.search", in: snapshot("search")) == nil, "memory cannot cross source scenes")
check(memory.control(named: "home.search", in: snapshot("home", device: "different-layout")) == nil, "memory cannot cross device layouts")
check(memory.control(named: "home.search", in: snapshot("home", blocked: true)) == nil, "overlay prevents memory reuse")
check(memory.control(named: "home.search", in: snapshot("home", at: now.addingTimeInterval(-5))) == nil,
      "observation predating verification cannot reuse memory")
check(memory.control(named: "home.search", in: snapshot("home", at: now.addingTimeInterval(31 * 86400))) == nil,
      "snapshot cannot extend the 30-day lifetime")
check(memory.control(named: "keyboard.a", in: controls) == nil, "unknown control is unavailable")

// Persisted data can outlive the code or be corrupt. Exercise the decoder and
// lookup together instead of manufacturing impossible states through record().
func editedMemory(_ original: PhoneLayoutMemory, _ update: (inout [String: Any]) -> Void) throws -> PhoneLayoutMemory {
    let data = try JSONEncoder().encode(original)
    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    update(&object)
    return try JSONDecoder().decode(PhoneLayoutMemory.self, from: JSONSerialization.data(withJSONObject: object))
}
let incompatible = try editedMemory(memory) { $0["version"] = 999 }
check(incompatible.control(named: "home.search", in: controls) == nil, "unsupported memory version is not replayed")
let stale = try editedMemory(memory) { object in
    var entries = object["controls"] as! [[String: Any]]
    entries[0]["confirmedAt"] = now.addingTimeInterval(-31 * 86400).timeIntervalSinceReferenceDate
    object["controls"] = entries
}
check(stale.control(named: "home.search", in: controls) == nil, "expired persisted location is not replayed")
let future = try editedMemory(memory) { object in
    var entries = object["controls"] as! [[String: Any]]
    entries[0]["confirmedAt"] = now.addingTimeInterval(3600).timeIntervalSinceReferenceDate
    object["controls"] = entries
}
check(future.control(named: "home.search", in: controls) == nil, "future-dated persisted verification is not replayed")
let unverified = try editedMemory(memory) { object in
    var entries = object["controls"] as! [[String: Any]]
    entries[0]["successes"] = 0
    object["controls"] = entries
}
check(unverified.control(named: "home.search", in: controls) == nil, "zero successful transitions cannot authorize replay")
let invalidGeometry = try editedMemory(memory) { object in
    var entries = object["controls"] as! [[String: Any]]
    var geometry = entries[0]["rect"] as! [String: Any]
    geometry["x"] = 1.5
    entries[0]["rect"] = geometry
    object["controls"] = entries
}
check(invalidGeometry.control(named: "home.search", in: controls) == nil, "persisted offscreen location is not replayed")

func rejectsRecord(_ name: String, control: String = "home.search", element: PhoneUIElement = search,
                   source: PhoneUISnapshot = snapshot("home", elements: [search], at: now.addingTimeInterval(-2)),
                   destination: PhoneUISnapshot = snapshot("search", at: now.addingTimeInterval(-1))) {
    rejects(name) {
        var memory = PhoneLayoutMemory()
        try memory.record(name: control, element: element, source: source, destination: destination)
    }
}
rejectsRecord("unchanged page is not success", destination: snapshot("home"))
rejectsRecord("unrelated page change is not search success", destination: snapshot("settings"))
rejectsRecord("source element must have been observed", source: snapshot("home"))
rejectsRecord("same ID with altered coordinates is not observed evidence",
              element: PhoneUIElement(id: search.id, label: search.label,
                                      rect: PhoneUIRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1), source: "ocr"))
rejectsRecord("different destination device", destination: snapshot("search", device: "other-phone"))
rejectsRecord("empty device identity", source: snapshot("home", elements: [search], device: ""),
              destination: snapshot("search", device: ""))
rejectsRecord("blocked source cannot teach a location", source: snapshot("home", elements: [search], blocked: true))
rejectsRecord("blocked destination cannot verify transition", destination: snapshot("search", blocked: true))
rejectsRecord("backwards observation order", destination: snapshot("search", at: now.addingTimeInterval(-3)))
rejectsRecord("unsupported learned control", control: "keyboard.a")
rejectsRecord("wrong origin scene", source: snapshot("settings", elements: [search], at: now.addingTimeInterval(-2)))

var navigation = PhoneLayoutMemory()
try navigation.record(name: "navigation.back", element: back,
                      source: snapshot("settings.wifi", elements: [back], at: now.addingTimeInterval(-2)),
                      destination: snapshot("settings", at: now.addingTimeInterval(-1)))
check(navigation.control(named: "navigation.back", in: snapshot("settings.wifi")) != nil,
      "verified Settings child-to-parent navigation is reusable")
check(navigation.control(named: "navigation.back", in: snapshot("settings.bluetooth")) == nil,
      "back location is scoped to its verified source page")
rejectsRecord("navigation cannot learn an unrelated destination", control: "navigation.back", element: back,
              source: snapshot("settings.wifi", elements: [back], at: now.addingTimeInterval(-2)),
              destination: snapshot("search", at: now.addingTimeInterval(-1)))

print("\(checks) phone-harness checks passed. Synthetic pages only; no network, model, Bluetooth, phone actions or performance claims.")

// Model IDs belong to the observed frame; fresh frames require strict re-identification.
do {
    let old = PhoneUIElement(id: "ocr.old", label: "主屏幕", rect: PhoneUIRect(x: 0.4, y: 0.5, width: 0.1, height: 0.03), source: "ocr")
    let previous = PhoneUISnapshot(deviceKey: "device", scene: "assistive-menu", elements: [old], capturedAt: Date())
    var fresh = previous
    fresh.elements[0].id = "ocr.new"
    precondition(fresh.reidentifiedElement("ocr.old", from: previous)?.id == "ocr.new")
    fresh.blockingOverlay = true; precondition(fresh.reidentifiedElement("ocr.old", from: previous) == nil)
    fresh.blockingOverlay = false; fresh.scene = "other"; precondition(fresh.reidentifiedElement("ocr.old", from: previous) == nil)
    fresh = previous; fresh.deviceKey = "different"; precondition(fresh.reidentifiedElement("ocr.old", from: previous) == nil)
    fresh = previous; fresh.elements[0].rect.x += 0.1; precondition(fresh.reidentifiedElement("ocr.old", from: previous) == nil)
    fresh = previous; fresh.elements.append(PhoneUIElement(id: "duplicate", label: old.label, rect: old.rect, source: "ocr")); precondition(fresh.reidentifiedElement("ocr.old", from: previous) == nil)
    fresh = previous; fresh.elements[0].label = "锁定屏幕"; precondition(fresh.reidentifiedElement("ocr.old", from: previous) == nil)
    print("7 fresh-frame target re-identification checks passed")
}
