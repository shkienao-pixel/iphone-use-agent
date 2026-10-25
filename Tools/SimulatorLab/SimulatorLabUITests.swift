import XCTest

/// Local interface checks on the lab simulator. No task is submitted to a model.
final class SimulatorLabUITests: XCTestCase {
    private let sela = XCUIApplication(bundleIdentifier: "com.example.phoneagent")
    private static let ownedFixtures: Set<String> = [
        "Sela simulator local draft 20261025",
        "Sela simulator navigation draft\nSecond line stays local",
        "Sela simulator cancel new task draft",
        "Sela simulator explicit discard fixture",
        "Sela simulator search navigation draft"
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        sela.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        sela.launch()
        XCTAssertTrue(sela.buttons["conversation.menu"].waitForExistence(timeout: 20))
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let tree = XCTAttachment(string: sela.debugDescription)
        tree.name = name + "-accessibility"
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func clearOwnedFixture(_ field: XCUIElement) {
        let original = field.value as? String ?? ""
        guard original.isEmpty || original == field.placeholderValue || Self.ownedFixtures.contains(original) else {
            XCTFail("保留非本轮固定夹具的草稿，未清理文字。"); return
        }
        tapStable(field)
        XCTAssertTrue(sela.keyboards.firstMatch.waitForExistence(timeout: 5))
        // The bottom-right insertion point is the end of these short fixtures.
        // Tapping the centre can leave the cursor at the start or in an IME word.
        for _ in 0..<2 {
            let value = field.value as? String ?? ""
            if value.isEmpty || value == field.placeholderValue { return }
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.95)).tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count + 1))
        }
        XCTAssertTrue((field.value as? String ?? "").isEmpty || field.value as? String == field.placeholderValue)
    }

    private func tapStable(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            let frame = element.frame
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            if element.isHittable && element.frame == frame { element.tap(); return }
        }
        XCTFail("界面元素仍在移动或不可点击。")
    }

    private func enterOwnedFixture(_ text: String) throws -> XCUIElement {
        let field = sela.textFields["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let value = field.value as? String ?? ""
        if !value.isEmpty && value != field.placeholderValue {
            guard Self.ownedFixtures.contains(value) else { throw XCTSkip("保留已有的非测试草稿。") }
            clearOwnedFixture(field)
        }
        field.tap(); field.typeText(text)
        XCTAssertEqual(field.value as? String, text)
        return field
    }

    func testEmptyNewTaskDoesNotOpenKeyboard() throws {
        let field = sela.textFields["composer.text"]
        let value = field.value as? String ?? ""
        if !value.isEmpty && value != field.placeholderValue {
            guard Self.ownedFixtures.contains(value) else { throw XCTSkip("保留已有的非测试草稿。") }
            clearOwnedFixture(field)
        }
        sela.buttons["conversation.menu"].tap()
        sela.buttons["sidebar.newTask"].tap()
        XCTAssertTrue(sela.staticTexts["home.title"].waitForExistence(timeout: 5))
        XCTAssertFalse(sela.keyboards.firstMatch.exists)
        capture("empty-new-task")
    }

    func testMultilineKeyboardAndToolsRoundTripPreserveDraft() throws {
        let text = "Sela simulator navigation draft\nSecond line stays local"
        let field = try enterOwnedFixture(text)
        XCTAssertTrue(sela.keyboards.firstMatch.exists)
        XCTAssertTrue(sela.buttons["composer.mic"].isHittable)
        XCTAssertTrue(sela.buttons["composer.send"].isHittable)
        XCTAssertLessThanOrEqual(field.frame.maxY, sela.keyboards.firstMatch.frame.minY + 1)
        capture("multiline-keyboard")
        sela.buttons["conversation.menu"].tap()
        tapStable(sela.buttons["sidebar.more"])
        tapStable(sela.buttons["tools.appConnections"])
        capture("app-connections-back-navigation")
        XCTAssertTrue(sela.buttons["返回工具与连接"].waitForExistence(timeout: 5))
        sela.buttons["返回工具与连接"].tap()
        sela.buttons["返回任务"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, text)
        clearOwnedFixture(field)
    }

    func testCancelNewTaskPreservesUnsentDraft() throws {
        let text = "Sela simulator cancel new task draft"
        let field = try enterOwnedFixture(text)
        sela.buttons["conversation.menu"].tap()
        sela.buttons["sidebar.newTask"].tap()
        capture("new-task-cancel-dialog")
        XCTAssertTrue(sela.buttons["继续编辑"].waitForExistence(timeout: 5))
        sela.buttons["继续编辑"].tap()
        XCTAssertEqual(field.value as? String, text)
        capture("cancel-new-task-preserves-draft")
        clearOwnedFixture(field)
    }

    func testConfirmNewTaskClearsOnlyOwnedDraft() throws {
        let field = try enterOwnedFixture("Sela simulator explicit discard fixture")
        sela.buttons["conversation.menu"].tap()
        tapStable(sela.buttons["sidebar.newTask"])
        XCTAssertTrue(sela.buttons["清空并新建"].waitForExistence(timeout: 5))
        sela.buttons["清空并新建"].tap()
        XCTAssertTrue(sela.staticTexts["home.title"].waitForExistence(timeout: 5))
        XCTAssertTrue((field.value as? String ?? "").isEmpty || field.value as? String == field.placeholderValue)
        XCTAssertFalse(sela.keyboards.firstMatch.exists)
        capture("explicit-discard-new-task")
    }

    func testSidebarSearchAndClosePreserveDraft() throws {
        let text = "Sela simulator search navigation draft"
        let field = try enterOwnedFixture(text)
        sela.buttons["conversation.menu"].tap()
        sela.buttons["sidebar.search.toggle"].tap()
        let search = sela.textFields["sidebar.search.field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Sela no matching record 20261025")
        capture("search-expanded")
        XCTAssertTrue(sela.staticTexts["没有找到相关对话"].waitForExistence(timeout: 5))
        sela.buttons["sidebar.search.toggle"].tap()
        XCTAssertTrue(sela.buttons["sidebar.newTask"].waitForExistence(timeout: 5))
        sela.buttons["关闭侧栏"].tap()
        XCTAssertEqual(field.value as? String, text)
        clearOwnedFixture(field)
    }

    func testHomeOpensWithoutModelConfiguration() {
        XCTAssertTrue(sela.textFields["composer.text"].exists)
        XCTAssertTrue(sela.buttons["conversation.menu"].isHittable)
        capture("home")
    }

    func testSidebarAndToolsNavigation() {
        sela.buttons["conversation.menu"].tap()
        XCTAssertTrue(sela.buttons["sidebar.newTask"].waitForExistence(timeout: 5))
        XCTAssertTrue(sela.buttons["sidebar.newConversation"].exists)
        capture("sidebar")
        sela.buttons["sidebar.more"].tap()
        XCTAssertTrue(sela.buttons["tools.phoneConnections"].waitForExistence(timeout: 5))
        XCTAssertTrue(sela.buttons["tools.appConnections"].exists)
        XCTAssertTrue(sela.buttons["tools.modelMemory"].exists)
        capture("tools")
        sela.buttons["tools.appConnections"].tap()
        XCTAssertTrue(sela.staticTexts["App 连接"].waitForExistence(timeout: 5))
        capture("app-connections")
    }

    func testDraftSurvivesRelaunchWithoutSubmission() throws {
        let field = sela.textFields["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let fixture = "Sela simulator local draft 20261025"
        let original = field.value as? String ?? ""
        if !original.isEmpty && original != field.placeholderValue && !Self.ownedFixtures.contains(original) {
            throw XCTSkip("已有非测试草稿，保留原文并跳过输入检查。")
        }
        field.tap()
        if let value = field.value as? String, !value.isEmpty, value != field.placeholderValue {
            clearOwnedFixture(field)
        }
        field.typeText(fixture)
        XCTAssertEqual(field.value as? String, fixture)
        capture("unsent-draft")
        sela.terminate()
        sela.launch()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, fixture)
        clearOwnedFixture(field)
    }
}
