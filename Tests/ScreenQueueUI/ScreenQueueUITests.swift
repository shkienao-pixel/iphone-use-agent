import XCTest

/// Dedicated simulator only. The explicit preview seeds synthetic queue data
/// and disables execution; these checks never submit a model or phone task.
final class ScreenQueueUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.example.phoneagent")
    private let first = "00000000-0000-4000-8000-000000000001"
    private let second = "00000000-0000-4000-8000-000000000002"
    private let third = "00000000-0000-4000-8000-000000000003"

    override func setUpWithError() throws { continueAfterFailure = false }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
    }
    private func remove(_ id: String) {
        let button = element("screenQueue.remove." + id)
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        if !button.isHittable { app.swipeUp() }
        button.tap()
        if app.buttons["移除"].waitForExistence(timeout: 1) { app.buttons["移除"].tap() }
        XCTAssertTrue(element("screenQueue.row." + id).waitForNonExistence(timeout: 5))
    }

    func testQueueOrderControlsAndChatDraft() throws {
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "--ui-page", "screen-queue", "--screen-queue-seed"]
        app.launch()
        XCTAssertTrue(element("screenQueue.panel").waitForExistence(timeout: 20))
        XCTAssertTrue(element("screenQueue.row." + first).waitForExistence(timeout: 5))
        XCTAssertTrue(element("screenQueue.row." + third).exists)
        capture("01-screen-queue-before-drag")

        let sourceCell = app.cells.containing(.any, identifier: "screenQueue.row." + third).firstMatch
        let handle = sourceCell.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'reorder' OR label CONTAINS '排序' OR label CONTAINS '排列'")).firstMatch
        if !handle.isHittable { app.swipeUp() }
        XCTAssertTrue(handle.isHittable)
        let destination = element("screenQueue.row." + first)
        if !destination.isHittable { app.swipeDown() }
        handle.press(forDuration: 0.8, thenDragTo: destination)
        let order = NSPredicate { _, _ in
            self.element("screenQueue.row." + self.third).frame.minY < self.element("screenQueue.row." + self.first).frame.minY
        }
        expectation(for: order, evaluatedWith: nil)
        waitForExpectations(timeout: 6)
        capture("02-screen-queue-after-real-drag")

        element("screenQueue.pause." + third).tap()
        XCTAssertTrue(element("screenQueue.start." + third).waitForExistence(timeout: 5))
        capture("03-screen-queue-single-paused")

        // Reopen the preview without reseeding: order and pause are on disk.
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "--ui-page", "screen-queue"]
        app.launch()
        XCTAssertTrue(element("screenQueue.start." + third).waitForExistence(timeout: 15))
        XCTAssertLessThan(element("screenQueue.row." + third).frame.minY, element("screenQueue.row." + first).frame.minY)
        remove(third)

        // Open the actual chat header and actual global sheet. No start button
        // is pressed here; the local draft must survive showing the queue.
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "--ui-page", "assistant"]
        app.launch()
        let draft = app.textFields["composer.text"]
        XCTAssertTrue(draft.waitForExistence(timeout: 15))
        draft.tap(); draft.typeText("Screen queue local draft")
        let entry = app.buttons["conversation.queue"]
        XCTAssertTrue(entry.exists); entry.tap()
        XCTAssertTrue(element("screenQueue.panel").waitForExistence(timeout: 5))
        capture("04-chat-header-queue-sheet")
        app.buttons["screenQueue.close"].tap()
        XCTAssertEqual(draft.value as? String, "Screen queue local draft")
        capture("05-chat-draft-preserved")

        entry.tap()
        remove(second); remove(first)
        XCTAssertTrue(element("screenQueue.empty").waitForExistence(timeout: 5))
        capture("06-screen-queue-empty")
    }

    func testTerminatingOneWaitingTaskKeepsOtherTasks() {
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "--ui-page", "screen-queue", "--screen-queue-seed"]
        app.launch()
        let stop = element("screenQueue.stop." + second)
        XCTAssertTrue(stop.waitForExistence(timeout: 20)); stop.tap()
        let confirmation = app.buttons.matching(identifier: "screenQueue.confirmStop")
            .matching(NSPredicate(format: "label == %@", "终止任务")).firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5)); confirmation.tap()
        XCTAssertTrue(element("screenQueue.row." + second).waitForNonExistence(timeout: 5))
        XCTAssertTrue(element("screenQueue.row." + first).exists)
        XCTAssertTrue(element("screenQueue.row." + third).exists)
        capture("07-terminate-one-keeps-the-others")
    }

    func testUnifiedConversationWeChatEntryPreservesDraft() {
        let sela = XCUIApplication(bundleIdentifier: "com.local.phoneagent.tedace337ee")
        sela.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "--ui-page", "assistant"]
        sela.launch()
        let draft = sela.textFields["composer.text"]
        XCTAssertTrue(draft.waitForExistence(timeout: 20))
        draft.tap(); draft.typeText("Keep this draft")
        let shortcut = sela.buttons["home.wechat.open"]
        XCTAssertTrue(shortcut.waitForExistence(timeout: 5))
        XCTAssertTrue(shortcut.isHittable)
        shortcut.tap()
        XCTAssertTrue(sela.textFields["wechat.shortcut.name"].waitForExistence(timeout: 5))
        XCTAssertTrue(sela.buttons["wechat.shortcut.filehelper"].exists)
        sela.buttons["关闭"].tap()
        XCTAssertEqual(draft.value as? String, "Keep this draft")
    }
}
