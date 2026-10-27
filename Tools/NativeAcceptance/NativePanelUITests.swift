import Foundation
import XCTest

/// Operator transport only. Business operations must run inside Sela's real Agent.
final class NativePanelUITests: XCTestCase {
    struct Command: Decodable {
        var id: UUID
        var session: UUID
        var operation: String
        var expiresAt: Double
        var bundle: String?
        var elementType: String?
        var identifier: String?
        var text: String?
        var index: Int?
        var x: Double?
        var y: Double?
        var x2: Double?
        var y2: Double?
        var frameID: UUID?
        var expectedValue: String?
    }
    enum TransportError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
    }
    let files = FileManager.default
    var lastFrame: (UUID, Date, String)?
    var session: UUID!
    var selaSession: String!
    var selaBundle: String!
    var root: URL!
    var allowedBundles: Set<String> {
        [selaBundle, "com.apple.springboard", "com.apple.mobilecal", "com.apple.reminders",
         "com.apple.Health", "com.apple.MobileAddressBook", "com.apple.mobileslideshow",
         "com.apple.Music", "com.apple.mobilenotes", "com.apple.shortcuts", "com.apple.Preferences",
         "com.apple.mobilesafari", "com.apple.DocumentsApp", "com.meituan.imeituan", "ctrip.com", "pro.ctrip.com"]
    }
    @MainActor func app(_ bundle: String?) throws -> XCUIApplication {
        let name = bundle ?? selaBundle!
        guard allowedBundles.contains(name) else { throw TransportError.invalid("App outside native test allowlist") }
        return XCUIApplication(bundleIdentifier: name)
    }
    @MainActor func element(_ command: Command, in app: XCUIApplication) throws -> XCUIElement {
        guard let name = command.identifier, !name.isEmpty, name.count <= 200 else {
            throw TransportError.invalid("An explicit UI identifier or label is required")
        }
        let query: XCUIElementQuery
        switch command.elementType ?? "button" {
        case "button": query = app.buttons
        case "textField": query = app.textFields
        case "textView": query = app.textViews
        case "searchField": query = app.searchFields
        case "switch": query = app.switches
        case "staticText": query = app.staticTexts
        case "cell": query = app.cells
        default: throw TransportError.invalid("Unsupported UI element type")
        }
        let matches: XCUIElementQuery
        if command.elementType == "textField" || command.elementType == "searchField" {
            matches = query.matching(NSPredicate(format: "identifier == %@ OR label == %@ OR placeholderValue == %@", name, name, name))
        } else {
            matches = query.matching(NSPredicate(format: "identifier == %@ OR label == %@", name, name))
        }
        let index = command.index ?? 0
        guard (0..<50).contains(index), matches.count > index else { throw TransportError.invalid("UI element is not present: " + name) }
        let result = matches.element(boundBy: index)
        guard result.isHittable else { throw TransportError.invalid("UI element is not visible/hittable: " + name) }
        guard result.isEnabled else { throw TransportError.invalid("UI element is disabled: " + name) }
        return result
    }
    @MainActor func snapshot(_ target: XCUIApplication, bundle: String) throws -> [String: Any] {
        guard bundle == "com.apple.springboard" || target.state == .runningForeground else {
            throw TransportError.invalid("Activate the target App before capture; background UI queries are excluded")
        }
        let secure = target.secureTextFields.firstMatch
        let key = target.textFields["API Key"]
        guard !(secure.exists && secure.isHittable),
              !(key.exists && key.isHittable) else {
            throw TransportError.invalid("Credential screens are excluded from acceptance capture")
        }
        let id = UUID(), date = Date()
        let png = "frame-" + id.uuidString + ".png"
        let tree = "frame-" + id.uuidString + ".txt"
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: root.appendingPathComponent(png), options: .atomic)
        let safeTree = target.debugDescription.components(separatedBy: .newlines).map { line in
            line.contains("SecureTextField") || line.contains("API Key") ? "[credential field omitted]" : line
        }.joined(separator: "\n")
        try safeTree.write(to: root.appendingPathComponent(tree), atomically: true, encoding: .utf8)
        lastFrame = (id, date, bundle)
        return ["frameID": id.uuidString, "capturedAt": date.timeIntervalSince1970, "image": png, "tree": tree]
    }
    @MainActor func perform(_ command: Command) throws -> [String: Any] {
        let target = try app(command.bundle)
        let foregroundOperations: Set<String> = ["tap", "type_text", "replace_composer", "swipe_up", "swipe_down",
                                                "read_fixture_note", "replace_observed_field", "tap_screen", "long_press_screen"]
        if foregroundOperations.contains(command.operation) {
            guard command.bundle == "com.apple.springboard" || target.state == .runningForeground else {
                throw TransportError.invalid("Activate the target App before interaction; background UI queries are excluded")
            }
        }
        switch command.operation {
        case "ping": return ["ready": true]
        case "snapshot": return try snapshot(target, bundle: command.bundle ?? selaBundle!)
        case "launch_sela":
            guard (command.bundle ?? selaBundle) == selaBundle else { throw TransportError.invalid("Wrong Sela target") }
            target.launchArguments = ["--sela-device-debug", selaSession!]
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.environment["SELA_SIMULATOR_ACTIVITY_FIXTURES"] == "1" {
                target.launchArguments.append("--sela-activity-fixtures")
            }
            #endif
            target.launch()
            guard target.buttons["打开任务与工具侧栏"].waitForExistence(timeout: 12) else {
                throw TransportError.invalid("Sela main UI did not become ready")
            }
        case "activate_app": target.activate()
        case "start_task":
            guard (command.bundle ?? selaBundle) == selaBundle, let goal = command.text,
                  !goal.isEmpty, goal.count <= 2500 else { throw TransportError.invalid("Invalid test goal") }
            target.terminate(); target.launchArguments = ["--sela-device-debug", selaSession!]; target.launch()
            guard target.buttons["打开任务与工具侧栏"].waitForExistence(timeout: 12) else { throw TransportError.invalid("Sela unavailable") }
            target.buttons["打开任务与工具侧栏"].tap()
            guard target.buttons["sidebar.newTask"].waitForExistence(timeout: 4) else { throw TransportError.invalid("New-task entry unavailable") }
            target.buttons["sidebar.newTask"].tap()
            let input = target.textFields["新任务内容"].exists ? target.textFields["新任务内容"] : target.textFields["Ask Sela"]
            guard input.waitForExistence(timeout: 5) else { throw TransportError.invalid("Task input unavailable") }
            input.tap(); input.typeText(goal)
            target.buttons["开始任务"].tap()
        case "tap":
            if command.bundle != "com.apple.springboard", XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists {
                throw TransportError.invalid("Handle the system alert explicitly before tapping App UI")
            }
            try element(command, in: target).tap()
        case "type_text":
            let identifier = command.identifier ?? ""
            // This exact production field is the non-secret shop search box;
            // its word "keyword" is unrelated to an API-key credential field.
            let nonSecretShopSearch = identifier == "paotui.keyword"
            guard let text = command.text, text.count <= 3000,
                  ["textField", "textView", "searchField"].contains(command.elementType ?? ""),
                  (nonSecretShopSearch || !identifier.localizedCaseInsensitiveContains("key")),
                  !identifier.localizedCaseInsensitiveContains("password") else {
                throw TransportError.invalid("Only non-secret test text is accepted")
            }
            let field = try element(command, in: target); field.tap(); field.typeText(text)
        case "replace_composer":
            guard (command.bundle ?? selaBundle) == selaBundle, let text = command.text,
                  !text.isEmpty, text.count <= 3000 else { throw TransportError.invalid("Invalid composer fixture") }
            let field = target.textFields["composer.text"]
            guard field.exists, field.isHittable, field.isEnabled, field.label == "和 Sela 聊天" else {
                throw TransportError.invalid("Navigate to the unified chat composer before entering a fixture")
            }
            func value() -> String { field.value as? String ?? "" }
            func empty() -> Bool { value().isEmpty || value() == field.placeholderValue }
            field.tap()
            if !empty() {
                field.press(forDuration: 1.1)
                let menu = target.buttons.matching(NSPredicate(format: "label == 'Select All' OR label == '全选'"))
                let item = target.menuItems.matching(NSPredicate(format: "label == 'Select All' OR label == '全选'"))
                if menu.firstMatch.exists && menu.firstMatch.isHittable { menu.firstMatch.tap() }
                else if item.firstMatch.exists && item.firstMatch.isHittable { item.firstMatch.tap() }
                field.typeText(XCUIKeyboardKey.delete.rawValue)
                guard empty() else { throw TransportError.invalid("Composer was not cleared; fixture was not submitted") }
            }
            field.typeText(text)
            guard value() == text else { throw TransportError.invalid("Composer differs from the exact fixture; do not send") }
            return ["inputMatched": true, "inputCharacters": text.count]
        case "swipe_up": target.swipeUp()
        case "swipe_down": target.swipeDown()
        case "read_fixture_note":
            guard command.bundle == "com.apple.mobilenotes", let frame = lastFrame,
                  command.frameID == frame.0, Date().timeIntervalSince(frame.1) <= 60,
                  let identifier = command.identifier, identifier.hasPrefix("Note[id="),
                  let title = command.expectedValue, title.hasPrefix("Sela测试-20261025-"), title.count <= 160 else {
                throw TransportError.invalid("A fresh exact test-note snapshot is required")
            }
            let matches = target.textViews.matching(identifier: identifier)
            guard matches.count == 1, matches.firstMatch.isHittable,
                  let value = matches.firstMatch.value as? String,
                  value.hasPrefix(title + "\n"), value.utf8.count <= 32000 else {
                throw TransportError.invalid("The exact visible fixture note was not found")
            }
            return ["fixtureTitle": title, "value": value, "utf8Bytes": value.utf8.count]
        case "replace_observed_field":
            guard command.bundle == "com.apple.shortcuts", let frame = lastFrame,
                  command.frameID == frame.0, Date().timeIntervalSince(frame.1) <= 60,
                  let expected = command.expectedValue, expected.count <= 120,
                  let text = command.text, text.hasPrefix("Sela测试-"), text.count <= 120 else {
                throw TransportError.invalid("A fresh Shortcuts field snapshot and exact old value are required")
            }
            let fields = target.textFields.allElementsBoundByIndex.filter {
                $0.isHittable && ($0.value as? String) == expected
            }
            guard fields.count == 1 else { throw TransportError.invalid("Expected one exact visible field") }
            let field = fields[0]; field.tap(); field.press(forDuration: 1.1)
            let select = target.buttons.matching(NSPredicate(format: "label == 'Select All' OR label == '全选'"))
            let menu = target.menuItems.matching(NSPredicate(format: "label == 'Select All' OR label == '全选'"))
            if select.firstMatch.exists && select.firstMatch.isHittable { select.firstMatch.tap() }
            else if menu.firstMatch.exists && menu.firstMatch.isHittable { menu.firstMatch.tap() }
            field.typeText(XCUIKeyboardKey.delete.rawValue)
            let remaining = field.value as? String ?? ""
            guard remaining.isEmpty || remaining == field.placeholderValue else {
                throw TransportError.invalid("Observed field was not cleared")
            }
            field.typeText(text)
            guard (field.value as? String) == text else { throw TransportError.invalid("Observed field replacement differs") }
            lastFrame = nil
            return ["inputMatched": true, "inputCharacters": text.count]
        case "drag_screen":
            guard let frame = lastFrame, command.frameID == frame.0, Date().timeIntervalSince(frame.1) <= 60,
                  frame.2 == (command.bundle ?? selaBundle!),
                  let x = command.x, let y = command.y, let x2 = command.x2, let y2 = command.y2,
                  (0...1).contains(x), (0...1).contains(y), (0...1).contains(x2), (0...1).contains(y2) else {
                throw TransportError.invalid("A fresh inspected frame and valid drag endpoints are required")
            }
            let from = target.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
            let to = target.coordinate(withNormalizedOffset: CGVector(dx: x2, dy: y2))
            from.press(forDuration: 0.3, thenDragTo: to)
            lastFrame = nil
        case "tap_screen", "long_press_screen":
            guard let frame = lastFrame, command.frameID == frame.0, Date().timeIntervalSince(frame.1) <= 60,
                  frame.2 == (command.bundle ?? selaBundle!),
                  let x = command.x, let y = command.y, (0...1).contains(x), (0...1).contains(y) else {
                throw TransportError.invalid("A recent, explicitly inspected snapshot is required for a screen tap")
            }
            let point = target.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
            if command.operation == "long_press_screen" { point.press(forDuration: 1.2) }
            else { point.tap() }
            lastFrame = nil
        case "notification_center":
            #if targetEnvironment(simulator)
            guard command.bundle == "com.apple.springboard", let frame = lastFrame,
                  command.frameID == frame.0, frame.2 == "com.apple.springboard",
                  Date().timeIntervalSince(frame.1) <= 60 else {
                throw TransportError.invalid("A fresh simulator SpringBoard frame is required")
            }
            let top = target.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.001))
            let lower = target.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.70))
            top.press(forDuration: 0.1, thenDragTo: lower)
            #else
            throw TransportError.invalid("Notification authorization experiments are simulator-only")
            #endif
        case "home": XCUIDevice.shared.press(.home)
        case "end_session": return ["ended": true]
        default: throw TransportError.invalid("Unknown operator operation")
        }
        return ["ok": true]
    }
    func write(_ data: [String: Any], to name: String) throws {
        try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]).write(to: root.appendingPathComponent(name), options: .atomic)
    }
    @MainActor func testNativeAcceptanceSession() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let token = env["NATIVE_ACCEPTANCE_SESSION"], let session = UUID(uuidString: token),
              let selaToken = env["SELA_DEBUG_SESSION"], UUID(uuidString: selaToken) != nil,
              let bundle = env["SELA_BUNDLE_ID"], !bundle.isEmpty else {
            throw TransportError.invalid("Explicit session and target environment are required")
        }
        self.session = session; selaSession = selaToken; selaBundle = bundle
        root = URL.documentsDirectory.appendingPathComponent("NativeAcceptance", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        try write(["session": token, "ready": true, "startedAt": Date().timeIntervalSince1970], to: "ready.json")
        print("NATIVE_ACCEPTANCE_READY")
        let input = root.appendingPathComponent("command.json")
        let deadline = Date().addingTimeInterval(4 * 3600)
        var seen = Set<UUID>()
        while Date() < deadline {
            if files.fileExists(atPath: input.path) {
                var result: [String: Any] = ["session": token, "finishedAt": Date().timeIntervalSince1970]
                var id: UUID?
                do {
                    guard (try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 20_000 else { throw TransportError.invalid("Command too large") }
                    let data = try Data(contentsOf: input)
                    guard data.count <= 20_000 else { throw TransportError.invalid("Command too large") }
                    let command: Command
                    do { command = try JSONDecoder().decode(Command.self, from: data) }
                    catch {
                        // CoreDevice creates a file before its bytes are fully
                        // transferred. Never consume an incomplete command.
                        let modified = try input.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date()
                        if Date().timeIntervalSince(modified) > 15 {
                            try files.removeItem(at: input)
                            try write(["session": token, "reason": "incomplete_or_invalid_json", "byteCount": data.count,
                                       "date": Date().timeIntervalSince1970], to: "transport-error-" + UUID().uuidString + ".json")
                        }
                        Thread.sleep(forTimeInterval: 0.15)
                        continue
                    }
                    id = command.id; try files.removeItem(at: input)
                    guard command.session == session, !seen.contains(command.id), command.expiresAt > Date().timeIntervalSince1970,
                          command.expiresAt - Date().timeIntervalSince1970 <= 65 else { throw TransportError.invalid("Expired or mismatched command") }
                    seen.insert(command.id); result["operation"] = command.operation
                    result.merge(try perform(command)) { _, new in new }; result["ok"] = true
                    if command.operation == "end_session" {
                        result["id"] = command.id.uuidString; try write(result, to: "result-" + command.id.uuidString + ".json"); return
                    }
                } catch { result["ok"] = false; result["error"] = error.localizedDescription }
                result["finishedAt"] = Date().timeIntervalSince1970
                if let id { result["id"] = id.uuidString; try write(result, to: "result-" + id.uuidString + ".json") }
                try write(result, to: "last-result.json")
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
    }
}
