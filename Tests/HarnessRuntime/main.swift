import Foundation

@MainActor final class OCRFixtures {
    let streamID = UUID()
    private var observations: [Date: [PhoneUIElement]] = [:]
    var queued: [[PhoneUIElement]] = []
    var advances = 0
    var recognitions = 0

    func frame(_ elements: [PhoneUIElement], stream: UUID? = nil) -> ScreenFrame {
        let value = ScreenFrame(capturedAt: Date(), captureID: stream ?? streamID)
        observations[value.capturedAt] = elements
        return value
    }
    func recognize(_ frame: ScreenFrame) throws -> [PhoneUIElement] {
        recognitions += 1
        guard let value = observations[frame.capturedAt] else { throw AgentError.message("missing OCR fixture") }
        return value
    }
    func next(_ after: Date) throws -> ScreenFrame {
        guard !queued.isEmpty else { throw AgentError.message("fixture sequence exhausted") }
        advances += 1
        return frame(queued.removeFirst())
    }
}

@main struct HarnessRuntimeChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); checks += 1
        }
        func element(_ id: String, _ label: String, _ x: Double, _ y: Double) -> PhoneUIElement {
            PhoneUIElement(id: id, label: label,
                           rect: PhoneUIRect(x: x - 0.04, y: y - 0.015, width: 0.08, height: 0.03), source: "ocr")
        }
        func object(_ value: String) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(value.utf8)) as! [String: Any]
        }
        func expectFallback(_ message: String, _ action: () async throws -> Void) async throws {
            do { try await action(); preconditionFailure(message) }
            catch is PhoneHarnessFallback { checks += 1 }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneHarnessRuntime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = [element("search", "Search", 0.5, 0.86), element("phone", "Phone", 0.2, 0.3),
                    element("safari", "Safari", 0.5, 0.3), element("settings", "Settings", 0.8, 0.3)]
        let keyboard = [element("search.field", "Search", 0.4, 0.08), element("cancel", "Cancel", 0.88, 0.08),
                        element("space", "Space", 0.5, 0.91), element("return", "Return", 0.88, 0.91)]
        let results = keyboard + [element("apps", "Apps", 0.15, 0.2), element("app.settings", "Settings", 0.3, 0.32)]
        // Geometry taken from saved phone screenshots: Settings uses a large,
        // left-aligned title and also has its own bottom Search control.
        let settings = [element("heading", "Settings", 0.19716, 0.14971),
                        element("wifi", "Wi-Fi", 0.22871, 0.44477),
                        element("bluetooth", "Bluetooth", 0.26498, 0.50073),
                        element("settings.search", "Search", 0.21767, 0.94695)]
        let touch = [element("heading", "Touch", 0.5, 0.08), element("assistive", "AssistiveTouch", 0.5, 0.3)]
        let accessibility = [element("heading", "Accessibility", 0.5, 0.08), element("voiceover", "VoiceOver", 0.5, 0.3)]

        // Exercise the production local macro with an injected OCR provider.
        // The fixture supplies only text/bounds; it does not replace dispatch,
        // classification, focus tracking, transition checks or persistence.
        let tape = OCRFixtures(), executor = MouseExecutor()
        let memoryURL = directory.appendingPathComponent("layout.json")
        let runtime = PhoneHarnessRuntime(executor: executor, memoryURL: memoryURL, recognize: tape.recognize)
        let first = tape.frame(home)
        let firstContext = try object(await runtime.context(for: first))
        expect(firstContext["scene"] as? String == "home", "Home must be recognized from current OCR")
        tape.queued = [keyboard, keyboard, results, settings]
        ModelProbe.calls = 0
        let receipt = try await runtime.execute(PhoneHarnessRequest(operation: .open_app, target: "Settings"),
                                                frame: first, mappedHome: false, nextFrame: tape.next)
        expect(executor.actions == [.tap, .press_key, .type, .tap], "Open App performs one local search/input/result macro")
        expect(tape.advances == 4, "Macro verifies search, selection, app result and destination")
        expect(ModelProbe.calls == 0, "Local macro does not make model calls")
        expect(receipt.summary.contains("settings"), "Receipt names the observed destination")
        expect(receipt.lastInputCompletedAt != nil && receipt.verifiedFrame != nil,
               "Receipt provides the actual completed input time and observed terminal frame")
        expect(receipt.verifiedFrame!.confirmedAt > receipt.lastInputCompletedAt!,
               "Terminal frame is confirmed after the last actual input completed")
        expect(receipt.verifiedFrame!.captureID == first.captureID,
               "Terminal frame remains on the original capture stream")
        expect(receipt.checkpointFact == nil && receipt.checkpointFrame == nil,
               "Other operations, including open_app using openSearch internally, do not produce a checkpoint fact")
        expect(FileManager.default.fileExists(atPath: memoryURL.path), "Verified search memory is persisted")
        let stored = try JSONDecoder().decode(PhoneLayoutMemory.self, from: Data(contentsOf: memoryURL))
        expect(stored.controls.contains { $0.name == "home.search" && $0.successes == 1 }, "Only verified search transition is learned")
        let restored = PhoneHarnessRuntime(executor: MouseExecutor(), memoryURL: memoryURL, recognize: tape.recognize)
        let restoredContext = try object(await restored.context(for: tape.frame(home)))
        expect(restoredContext["remembered_search"] as? Bool == true, "New runtime restores persisted search layout")

        // A new frame may still show the original page, animation, or search
        // without results. Wait for evidence without replaying any inputs.
        let delayedTape = OCRFixtures(), delayedExecutor = MouseExecutor()
        let delayed = PhoneHarnessRuntime(executor: delayedExecutor,
            memoryURL: directory.appendingPathComponent("delayed.json"), recognize: delayedTape.recognize)
        delayedTape.queued = [home, [], keyboard, keyboard, keyboard, results, results, [], settings]
        let delayedReceipt = try await delayed.execute(PhoneHarnessRequest(operation: .open_app, target: "Settings"),
            frame: delayedTape.frame(home), mappedHome: false, nextFrame: delayedTape.next)
        expect(delayedExecutor.actions == [.tap, .press_key, .type, .tap],
               "Delayed search, results and destination never replay clicks or typing")
        expect(delayedTape.advances == 9 && delayedReceipt.summary.contains("settings"),
               "Original and transitional frames are observed until the requested app is recognized")
        expect(delayedReceipt.verifiedFrame != nil && delayedReceipt.verifiedFrame!.confirmedAt == delayedReceipt.verifiedFrame!.capturedAt,
               "Receipt retains the actual terminal frame rather than constructing a synthetic confirmation")

        let homeFirstTape = OCRFixtures(), homeFirstExecutor = MouseExecutor()
        let homeFirst = PhoneHarnessRuntime(executor: homeFirstExecutor,
            memoryURL: directory.appendingPathComponent("home-first.json"), recognize: homeFirstTape.recognize)
        homeFirstTape.queued = [settings, [], home, keyboard, keyboard, results, settings]
        _ = try await homeFirst.execute(PhoneHarnessRequest(operation: .open_app, target: "Settings"),
            frame: homeFirstTape.frame(touch), mappedHome: true, nextFrame: homeFirstTape.next)
        expect(homeFirstExecutor.actions == [.press_key, .tap, .press_key, .type, .tap],
               "Opening an app from a child page presses Home only once before the normal macro")
        expect(homeFirstTape.advances == 7, "App opening waits for confirmed Home and verifies the selection before typing")

        let idleReceipt = try await delayed.execute(PhoneHarnessRequest(operation: .open_search),
            frame: delayedTape.frame(keyboard), mappedHome: false, nextFrame: delayedTape.next)
        expect(idleReceipt.lastInputCompletedAt == nil && idleReceipt.verifiedFrame == nil,
               "An already-open search issues no input and does not invent a completed input time")
        expect(delayedExecutor.actions.count == 4, "Idempotent search does not dispatch an input")
        expect(idleReceipt.checkpointFact?.source == .alreadyVisible && idleReceipt.checkpointFact?.inputCompletedAt == nil,
               "Already visible search records the observed branch without inventing input")
        expect(idleReceipt.checkpointFact?.verificationScope == .searchSceneOnly && idleReceipt.checkpointFrame?.capturedAt == idleReceipt.checkpointFact?.capturedAt,
               "Existing classifier proves only a search-like scene and preserves the actual observation")

        // Run actual open_search against deterministic offline OCR and frame
        // providers. Counts include the old local work; there are no extra
        // model, frame-provider, OCR or input calls to construct the fact.
        let checkpointTape = OCRFixtures(), checkpointExecutor = MouseExecutor()
        let checkpointRuntime = PhoneHarnessRuntime(executor: checkpointExecutor,
            memoryURL: directory.appendingPathComponent("checkpoint.json"), recognize: checkpointTape.recognize)
        let sourceFrame = checkpointTape.frame(home)
        checkpointTape.queued = [keyboard]
        ModelProbe.calls = 0
        let opened = try await checkpointRuntime.execute(PhoneHarnessRequest(operation: .open_search),
            frame: sourceFrame, mappedHome: false, nextFrame: checkpointTape.next)
        expect(checkpointExecutor.actions == [.tap] && checkpointTape.advances == 1 && checkpointTape.recognitions == 2 && ModelProbe.calls == 0,
               "Opening search retains one tap, one later frame, two OCR calls and no model calls")
        expect(opened.checkpointFact?.source == .afterInput && opened.checkpointFact?.verificationScope == .searchSceneOnly,
               "Search transition preserves its input branch and honest classifier scope")
        expect(opened.checkpointFact?.captureID == sourceFrame.captureID && opened.checkpointFrame?.capturedAt == opened.checkpointFact?.capturedAt,
               "Search transition references its actual post-input frame on the original capture stream")
        expect(opened.checkpointFact?.inputCompletedAt == opened.lastInputCompletedAt && opened.checkpointFact!.capturedAt > opened.lastInputCompletedAt!,
               "Observed pixels and confirmation follow the actual input boundary")
        let oldGeneration = opened.checkpointFact!.runtimeGeneration
        checkpointRuntime.reset()
        expect(checkpointRuntime.checkpointRuntimeGeneration != oldGeneration,
               "Reset invalidates the prior runtime generation")
        let reconnectTape = OCRFixtures(), reconnectExecutor = MouseExecutor()
        let initialConnection = reconnectExecutor.ble.pointerConnectionGeneration
        let reconnected = PhoneHarnessRuntime(executor: reconnectExecutor,
            memoryURL: directory.appendingPathComponent("reconnected.json"), recognize: { frame in
                reconnectExecutor.ble.pointerConnectionGeneration = UUID()
                return try reconnectTape.recognize(frame)
            })
        try await expectFallback("Same-accessory reconnection during OCR must reject the operation before producing a receipt") {
            _ = try await reconnected.execute(PhoneHarnessRequest(operation: .open_search),
                frame: reconnectTape.frame(keyboard), mappedHome: false, nextFrame: reconnectTape.next)
        }
        expect(reconnectExecutor.actions.isEmpty && reconnectTape.advances == 0 &&
               initialConnection != reconnectExecutor.ble.pointerConnectionGeneration,
               "Reconnection cannot bless old OCR or dispatch another input")

        let boundedTape = OCRFixtures(), boundedExecutor = MouseExecutor()
        let bounded = PhoneHarnessRuntime(executor: boundedExecutor,
            memoryURL: directory.appendingPathComponent("bounded.json"), recognize: boundedTape.recognize)
        boundedTape.queued = Array(repeating: home, count: 13)
        try await expectFallback("A transition that never occurs must stop within the frame cap") {
            _ = try await bounded.execute(PhoneHarnessRequest(operation: .open_search),
                frame: boundedTape.frame(home), mappedHome: false, nextFrame: boundedTape.next)
        }
        expect(boundedTape.advances == 12 && boundedTape.queued.count == 1,
               "A high-rate stream cannot bypass the twelve-frame transition bound")
        expect(boundedExecutor.actions == [.tap], "Timeout never replays the search click")

        let slowTape = OCRFixtures(), slowExecutor = MouseExecutor()
        let slow = PhoneHarnessRuntime(executor: slowExecutor,
            memoryURL: directory.appendingPathComponent("slow.json"), recognize: slowTape.recognize)
        let slowBegan = Date()
        var slowRequests = 0
        try await expectFallback("A slow frame provider must not extend the local transition wait indefinitely") {
            _ = try await slow.execute(PhoneHarnessRequest(operation: .open_search),
                frame: slowTape.frame(home), mappedHome: false, nextFrame: { _ in
                    slowRequests += 1
                    try await Task.sleep(nanoseconds: 4_000_000_000)
                    return slowTape.frame(keyboard)
                })
        }
        expect(Date().timeIntervalSince(slowBegan) < 3.5 && slowRequests == 1,
               "The two-second transition deadline cancels a cooperative frame wait")
        expect(slowExecutor.actions == [.tap], "A deadline does not retry physical input")

        // The magnifier in the real Home search pill was recognized as "Q".
        // This exact alias at the observed centered pill geometry must work.
        let magnifierHome = home.filter { $0.id != "search" } + [element("search", "Q Search", 0.49842, 0.81541)]
        let magnifierTape = OCRFixtures(), magnifierExecutor = MouseExecutor()
        let magnifierRuntime = PhoneHarnessRuntime(executor: magnifierExecutor,
            memoryURL: directory.appendingPathComponent("magnifier.json"), recognize: magnifierTape.recognize)
        let magnifierFrame = magnifierTape.frame(magnifierHome)
        let magnifierContext = try object(await magnifierRuntime.context(for: magnifierFrame))
        expect(magnifierContext["scene"] as? String == "home", "Real Home Q Search OCR must classify as Home")
        magnifierTape.queued = [keyboard]
        _ = try await magnifierRuntime.execute(PhoneHarnessRequest(operation: .open_search),
            frame: magnifierFrame, mappedHome: false, nextFrame: magnifierTape.next)
        expect(magnifierExecutor.actions == [.tap] && magnifierTape.advances == 1,
               "Real Home Q Search pill opens Search with one verified tap")

        // Target and overlay failures must not send even an initial click.
        let safeTape = OCRFixtures(), safeExecutor = MouseExecutor()
        let safe = PhoneHarnessRuntime(executor: safeExecutor, memoryURL: directory.appendingPathComponent("safe.json"), recognize: safeTape.recognize)
        let settingsFrame = safeTape.frame(settings)
        let actualSettingsContext = try object(await safe.context(for: settingsFrame))
        expect(actualSettingsContext["scene"] as? String == "settings", "Large left Settings title with bottom Search is Settings, not Home")
        try await expectFallback("Settings bottom Search cannot become a Home search target") {
            _ = try await safe.execute(PhoneHarnessRequest(operation: .open_search),
                frame: settingsFrame, mappedHome: false, nextFrame: safeTape.next)
        }
        expect(safeExecutor.actions.isEmpty, "open_search on real Settings geometry dispatches no input")
        let blocked = safeTape.frame(home + [element("permission", "Allow", 0.5, 0.5)])
        let blockedContext = try object(await safe.context(for: blocked))
        expect(blockedContext["blocked"] as? Bool == true, "System permission text blocks local dispatch")
        try await expectFallback("Overlay must stop semantic clicks") {
            _ = try await safe.execute(PhoneHarnessRequest(operation: .tap, target: "search"), frame: blocked, mappedHome: false, nextFrame: safeTape.next)
        }
        try await expectFallback("Missing element must require a new observation") {
            _ = try await safe.execute(PhoneHarnessRequest(operation: .tap, target: "missing"), frame: safeTape.frame(home), mappedHome: false, nextFrame: safeTape.next)
        }
        let duplicates = [element("one", "Continue", 0.3, 0.3), element("two", "Continue", 0.7, 0.3)]
        try await expectFallback("Duplicate labels must not choose an arbitrary element") {
            _ = try await safe.execute(PhoneHarnessRequest(operation: .tap, target: "Continue"), frame: safeTape.frame(duplicates), mappedHome: false, nextFrame: safeTape.next)
        }
        try await expectFallback("Unmapped Home must not press the middle button") {
            _ = try await safe.execute(PhoneHarnessRequest(operation: .home), frame: safeTape.frame(settings), mappedHome: false, nextFrame: safeTape.next)
        }
        try await expectFallback("Unfocused typing must not enter text") {
            _ = try await safe.execute(PhoneHarnessRequest(operation: .type_text, text: "test"), frame: safeTape.frame(settings), mappedHome: false, nextFrame: safeTape.next)
        }
        let notesWithoutKeyboard = safeTape.frame([element("notes", "Notes", 0.5, 0.08),
                                                   element("done", "Done", 0.9, 0.08),
                                                   element("body", "A new note", 0.3, 0.24)])
        let notesContext = try object(await safe.context(for: notesWithoutKeyboard))
        expect(notesContext["keyboard_focus_confirmed"] as? Bool == false,
               "A Notes editor with a hidden software keyboard does not invent confirmed focus")
        try await expectFallback("Hidden-keyboard Notes keeps the existing single-step fallback instead of authorizing semantic paste") {
            _ = try await safe.execute(PhoneHarnessRequest(operation: .press_key, target: "paste"),
                frame: notesWithoutKeyboard, mappedHome: false, nextFrame: safeTape.next)
        }
        expect(safeExecutor.actions.isEmpty, "Failed preconditions dispatch no inputs")

        // An overlay can appear after the macro has already begun. Every
        // intermediate observation must gate the next primitive input.
        let permission = element("permission", "Allow", 0.5, 0.5)
        let searchBlockTape = OCRFixtures(), searchBlockExecutor = MouseExecutor()
        let searchBlocked = PhoneHarnessRuntime(executor: searchBlockExecutor,
            memoryURL: directory.appendingPathComponent("blocked-search.json"), recognize: searchBlockTape.recognize)
        searchBlockTape.queued = [keyboard + [permission]]
        try await expectFallback("Permission prompt over Search must stop keyboard input") {
            _ = try await searchBlocked.execute(PhoneHarnessRequest(operation: .open_app, target: "Settings"),
                frame: searchBlockTape.frame(home), mappedHome: false, nextFrame: searchBlockTape.next)
        }
        expect(searchBlockExecutor.actions == [.tap], "Overlay after search prevents select-all and typing")
        let delayedBlockTape = OCRFixtures(), delayedBlockExecutor = MouseExecutor()
        let delayedBlocked = PhoneHarnessRuntime(executor: delayedBlockExecutor,
            memoryURL: directory.appendingPathComponent("delayed-block.json"), recognize: delayedBlockTape.recognize)
        delayedBlockTape.queued = [home, keyboard + [permission], keyboard]
        try await expectFallback("An overlay on a later transition frame must stop the wait immediately") {
            _ = try await delayedBlocked.execute(PhoneHarnessRequest(operation: .open_app, target: "Settings"),
                frame: delayedBlockTape.frame(home), mappedHome: false, nextFrame: delayedBlockTape.next)
        }
        expect(delayedBlockTape.advances == 2 && delayedBlockTape.queued.count == 1 && delayedBlockExecutor.actions == [.tap],
               "The wait neither observes past a blocking prompt nor enters text")
        let resultBlockTape = OCRFixtures(), resultBlockExecutor = MouseExecutor()
        let resultBlocked = PhoneHarnessRuntime(executor: resultBlockExecutor,
            memoryURL: directory.appendingPathComponent("blocked-results.json"), recognize: resultBlockTape.recognize)
        resultBlockTape.queued = [keyboard, keyboard, results + [permission]]
        try await expectFallback("Permission prompt over results must stop result selection") {
            _ = try await resultBlocked.execute(PhoneHarnessRequest(operation: .open_app, target: "Settings"),
                frame: resultBlockTape.frame(home), mappedHome: false, nextFrame: resultBlockTape.next)
        }
        expect(resultBlockExecutor.actions == [.tap, .press_key, .type], "Overlay after input prevents final result click")
        let topHitTape = OCRFixtures(), topHitExecutor = MouseExecutor()
        let topHit = PhoneHarnessRuntime(executor: topHitExecutor,
            memoryURL: directory.appendingPathComponent("top-hit.json"), recognize: topHitTape.recognize)
        topHitTape.queued = [keyboard, keyboard] + Array(repeating: keyboard + [element("hit", "Top Hit", 0.15, 0.2), element("result", "Settings", 0.3, 0.32)], count: 12)
        try await expectFallback("Top Hit alone is not proof of an installed app result") {
            _ = try await topHit.execute(PhoneHarnessRequest(operation: .open_app, target: "Settings"),
                frame: topHitTape.frame(home), mappedHome: false, nextFrame: topHitTape.next)
        }
        expect(topHitExecutor.actions == [.tap, .press_key, .type], "Unclassified Top Hit result is not clicked")

        let wrongTape = OCRFixtures(), wrongExecutor = MouseExecutor()
        let wrong = PhoneHarnessRuntime(executor: wrongExecutor,
            memoryURL: directory.appendingPathComponent("wrong-app.json"), recognize: wrongTape.recognize)
        wrongTape.queued = [keyboard, keyboard, results] + Array(repeating: [element("mail", "Mail", 0.5, 0.08)], count: 12)
        try await expectFallback("Leaving search for an unidentified or incorrect app is not successful app opening") {
            _ = try await wrong.execute(PhoneHarnessRequest(operation: .open_app, target: "Settings"),
                frame: wrongTape.frame(home), mappedHome: false, nextFrame: wrongTape.next)
        }
        expect(wrongExecutor.actions == [.tap, .press_key, .type, .tap],
               "A wrong destination stops after the original app-result click")

        let changedTape = OCRFixtures(), changedExecutor = MouseExecutor()
        let changed = PhoneHarnessRuntime(executor: changedExecutor,
            memoryURL: directory.appendingPathComponent("changed-stream.json"), recognize: changedTape.recognize)
        var changedRequests = 0
        do {
            _ = try await changed.execute(PhoneHarnessRequest(operation: .open_app, target: "Settings"),
                frame: changedTape.frame(home), mappedHome: false, nextFrame: { _ in
                    changedRequests += 1
                    return changedTape.frame(changedRequests == 1 ? home : keyboard,
                        stream: changedRequests == 1 ? changedTape.streamID : UUID())
                })
            preconditionFailure("A changed shared stream must stop transition waiting")
        } catch let error as AgentError {
            expect(error.localizedDescription.contains("共享"), "Stream changes identify the reason for stopping")
        }
        expect(changedRequests == 2 && changedExecutor.actions == [.tap],
               "A changed stream stops immediately, without another frame or keyboard input")

        let failedTape = OCRFixtures(), failedExecutor = MouseExecutor()
        let failed = PhoneHarnessRuntime(executor: failedExecutor,
            memoryURL: directory.appendingPathComponent("frame-error.json"), recognize: failedTape.recognize)
        var failedRequests = 0
        do {
            _ = try await failed.execute(PhoneHarnessRequest(operation: .open_search),
                frame: failedTape.frame(home), mappedHome: false, nextFrame: { _ in
                    failedRequests += 1
                    throw AgentError.message("capture failed")
                })
            preconditionFailure("Capture failures must propagate instead of retrying")
        } catch let error as AgentError {
            expect(error.localizedDescription == "capture failed", "The original capture error is preserved")
        }
        expect(failedRequests == 1 && failedExecutor.actions == [.tap], "A capture error never replays input")

        // An unlabelled Back position becomes reusable only after a raw tap is
        // followed by an actual different, recognized Settings page.
        let backTape = OCRFixtures(), backExecutor = MouseExecutor()
        let backURL = directory.appendingPathComponent("back.json")
        let backRuntime = PhoneHarnessRuntime(executor: backExecutor, memoryURL: backURL, recognize: backTape.recognize)
        let child = backTape.frame(touch)
        _ = try await backRuntime.context(for: child)
        try await expectFallback("Unknown Back position must first be located") {
            _ = try await backRuntime.execute(PhoneHarnessRequest(operation: .back), frame: child, mappedHome: false, nextFrame: backTape.next)
        }
        expect(backExecutor.actions.isEmpty, "Unlearned Back sends no input")
        let rawBack = AgentAction(kind: .tap, x: 0.1, y: 0.08, reason: "offline observed back")
        try await backExecutor.execute(rawBack, frame: child)
        await backRuntime.didExecute(rawBack, frame: child)
        _ = try await backRuntime.context(for: backTape.frame(touch))
        expect(!FileManager.default.fileExists(atPath: backURL.path), "An unchanged page cannot teach Back")
        let childAgain = backTape.frame(touch)
        _ = try await backRuntime.context(for: childAgain)
        try await backExecutor.execute(rawBack, frame: childAgain)
        await backRuntime.didExecute(rawBack, frame: childAgain)
        _ = try await backRuntime.context(for: backTape.frame(accessibility))
        let backMemory = try JSONDecoder().decode(PhoneLayoutMemory.self, from: Data(contentsOf: backURL))
        expect(backMemory.controls.contains { $0.name == "navigation.back" && $0.scene == "settings.touch" }, "Real child-to-parent transition teaches Back")
        let learnedContext = try object(await backRuntime.context(for: backTape.frame(touch)))
        expect(learnedContext["remembered_back"] as? Bool == true, "Learned Back is advertised for its source scene")
        backTape.queued = [touch, [], accessibility]
        _ = try await backRuntime.execute(PhoneHarnessRequest(operation: .back), frame: backTape.frame(touch), mappedHome: false, nextFrame: backTape.next)
        expect(backExecutor.actions == [.tap, .tap, .tap], "Learned Back performs one additional primitive tap")
        expect(backTape.advances == 3, "Back waits through the original page and transition before confirming the parent")

        let resetTape = OCRFixtures(), resetExecutor = MouseExecutor()
        let resetURL = directory.appendingPathComponent("reset.json")
        let resetRuntime = PhoneHarnessRuntime(executor: resetExecutor, memoryURL: resetURL, recognize: resetTape.recognize)
        let resetChild = resetTape.frame(touch)
        _ = try await resetRuntime.context(for: resetChild)
        try await resetExecutor.execute(rawBack, frame: resetChild)
        await resetRuntime.didExecute(rawBack, frame: resetChild)
        resetRuntime.reset()
        _ = try await resetRuntime.context(for: resetTape.frame(accessibility))
        expect(!FileManager.default.fileExists(atPath: resetURL.path), "Lifecycle reset discards pending unverified learning")

        // Cancelling after search's first input must stop the rest of the macro.
        let cancelTape = OCRFixtures(), cancelExecutor = MouseExecutor()
        let cancelling = PhoneHarnessRuntime(executor: cancelExecutor, memoryURL: directory.appendingPathComponent("cancel.json"), recognize: cancelTape.recognize)
        do {
            _ = try await cancelling.execute(PhoneHarnessRequest(operation: .open_app, target: "Settings"),
                frame: cancelTape.frame(home), mappedHome: false, nextFrame: { _ in throw CancellationError() })
            preconditionFailure("Cancelled frame acquisition must stop macro")
        } catch is CancellationError { checks += 1 }
        expect(cancelExecutor.actions == [.tap], "Cancellation prevents typing or result clicks")

        let waitingCancelTape = OCRFixtures(), waitingCancelExecutor = MouseExecutor()
        let waitingCancel = PhoneHarnessRuntime(executor: waitingCancelExecutor,
            memoryURL: directory.appendingPathComponent("waiting-cancel.json"), recognize: waitingCancelTape.recognize)
        var waitingCancelRequests = 0
        let waitingCancelBegan = Date()
        let waitingTask = Task { @MainActor in
            try await waitingCancel.execute(PhoneHarnessRequest(operation: .open_app, target: "Settings"),
                frame: waitingCancelTape.frame(home), mappedHome: false, nextFrame: { _ in
                    waitingCancelRequests += 1
                    try await Task.sleep(nanoseconds: 4_000_000_000)
                    return waitingCancelTape.frame(keyboard)
                })
        }
        while waitingCancelRequests == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        waitingTask.cancel()
        do {
            _ = try await waitingTask.value
            preconditionFailure("Task cancellation must stop an in-flight transition wait")
        } catch is CancellationError { checks += 1 }
        expect(waitingCancelExecutor.actions == [.tap] && waitingCancelRequests == 1,
               "Cancelling a frame wait sends no further primitive input")
        expect(Date().timeIntervalSince(waitingCancelBegan) < 1.5,
               "Cancellation propagates before the transition timeout")

        // Route the same production runtime through AgentEngine's phone_tool
        // branch. Frames remain on one stream; only their OCR observations vary.
        func engineCheck(changeStream: Bool) async throws {
            let capture = CaptureService(), engineExecutor = MouseExecutor(), engineTape = OCRFixtures()
            let newStream = UUID()
            capture.frameProvider = {
                let count = engineExecutor.actions.count
                let labels = count == 0 ? home : count == 1 ? keyboard : count < 4 ? results : settings
                return engineTape.frame(labels, stream: changeStream && count > 0 ? newStream : engineTape.streamID)
            }
            let engineRuntime = PhoneHarnessRuntime(executor: engineExecutor,
                memoryURL: directory.appendingPathComponent(changeStream ? "engine-changed.json" : "engine.json"), recognize: engineTape.recognize)
            let engine = AgentEngine(capture: capture, executor: engineExecutor)
            engine.phoneHarness = engineRuntime
            var config = AgentSettings(); config.startDelay = 0; config.stepInterval = 0.4; config.maxSteps = 1; config.continuousExecution = false
            PrivacyConsent.grant(config)
            defer { PrivacyConsent.revoke() }
            ModelProbe.calls = 0; ModelProbe.delay = 0
            ModelProbe.action = AgentAction(kind: .phone_tool, text: #"{"operation":"open_app","target":"Settings"}"#, reason: "open via local harness")
            engine.start(task: "Open Settings", settings: config)
            let deadline = Date().addingTimeInterval(5)
            while !engine.executionSettled && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            expect(engine.executionSettled, "Engine macro must settle within offline deadline")
            if changeStream {
                expect(engineExecutor.actions == [.tap], "Shared-source change prevents remaining macro inputs")
                expect(engine.error.contains("共享"), "Source change reports why the macro stopped")
            } else {
                expect(engineExecutor.actions == [.tap, .press_key, .type, .tap], "Engine delegates phone_tool to production runtime primitives")
                expect(engine.logs.contains { $0.title == "手机工具回执" }, "Engine records the local verification receipt")
                expect(ModelProbe.calls == 1, "One model action starts the entire local macro")
            }
            expect(!engineExecutor.actions.contains(.phone_tool), "Semantic phone_tool never reaches the raw executor")
        }
        try await engineCheck(changeStream: false)
        try await engineCheck(changeStream: true)
        func profileOCR(_ id: String, _ text: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> PhoneUIElement {
            .init(id: id, label: text, rect: .init(x: x, y: y, width: width, height: height), source: "ocr")
        }
        let profileCandidate = PhoneUISnapshot(deviceKey: "offline-roi-candidate", scene: "unknown", elements: [
            profileOCR("account", "Weixin ID: filehelper", 0.214, 0.170, 0.347, 0.016),
            profileOCR("description-1", "Transfer text, images, audio and video files", 0.217, 0.263, 0.738, 0.020),
            profileOCR("description-2", "between your device and your PC", 0.217, 0.283, 0.581, 0.020),
            profileOCR("messages", "• Messages", 0.378, 0.347, 0.247, 0.021)
        ], capturedAt: Date())
        expect(WeChatBuiltinWorkflowTitleOCR.isCandidate(profileCandidate), "Only a complete actual reserved-account profile candidate requests title ROI OCR")
        var recordingIndicator = profileCandidate
        recordingIndicator.elements.append(profileOCR("status-recording", "•", 0.3186, 0.0281, 0.0305, 0.0125))
        expect(WeChatBuiltinWorkflowTitleOCR.isCandidate(recordingIndicator),
            "The real status-bar recording indicator is outside the navigation-title exclusion area")
        let roiBox = CGRect(x: 0.025, y: 0.55, width: 0.52, height: 0.29)
        let fullBox = WeChatBuiltinWorkflowTitleOCR.fullFrameRect(roiBox)
        expect(abs(fullBox.x - 0.21375) < 0.000001 && abs(fullBox.y - 0.1328) < 0.000001 &&
               abs(fullBox.width - 0.286) < 0.000001 && abs(fullBox.height - 0.0232) < 0.000001,
            "ROI-relative coordinates map both axes and sizes into the exact original full-frame coordinate system")
        let actualTitle = PhoneUIElement(id: "actual-roi-result", label: "文件传输助手", rect: fullBox, source: "ocr")
        let additions = WeChatBuiltinWorkflowTitleOCR.uniqueAddition([actualTitle], to: profileCandidate)
        expect(additions == [actualTitle], "The supplemental element preserves the actual recognized label, rectangle and source")
        expect(WeChatBuiltinWorkflowTitleOCR.uniqueAddition([actualTitle, actualTitle], to: profileCandidate).isEmpty,
            "Duplicate title recognition cannot select an arbitrary ROI result")
        expect(WeChatBuiltinWorkflowTitleOCR.uniqueAddition([], to: profileCandidate).isEmpty,
            "Missing title OCR creates no preset or fallback title")
        var unknownTitle = actualTitle; unknownTitle.label = "another profile"
        expect(WeChatBuiltinWorkflowTitleOCR.uniqueAddition([unknownTitle], to: profileCandidate).isEmpty,
            "An unrelated actual ROI label is not corrected into the expected helper name")
        var modelTitle = actualTitle; modelTitle.source = "model"
        expect(WeChatBuiltinWorkflowTitleOCR.uniqueAddition([modelTitle], to: profileCandidate).isEmpty,
            "Model text is never accepted as actual ROI OCR")
        var existingTitle = profileCandidate; existingTitle.elements.append(actualTitle)
        expect(!WeChatBuiltinWorkflowTitleOCR.isCandidate(existingTitle) &&
               WeChatBuiltinWorkflowTitleOCR.uniqueAddition([actualTitle], to: existingTitle).isEmpty,
            "An already-observed exact title is neither re-recognized nor duplicated")
        for id in ["account", "description-1", "description-2", "messages"] {
            var missing = profileCandidate; missing.elements.removeAll { $0.id == id }
            expect(!WeChatBuiltinWorkflowTitleOCR.isCandidate(missing), "Missing candidate field does not trigger supplementary recognition: " + id)
        }
        for account in ["Weixin ID: tilehelper", "Weixin ID: FileHelper", "Weixin ID: wxid_someone"] {
            var wrong = profileCandidate; wrong.elements[0].label = account
            expect(!WeChatBuiltinWorkflowTitleOCR.isCandidate(wrong), "Candidate account is never repaired or case-normalized: " + account)
        }
        var duplicateAccount = profileCandidate
        var otherAccount = profileCandidate.elements[0]; otherAccount.id = "other-account"
        duplicateAccount.elements.append(otherAccount)
        expect(!WeChatBuiltinWorkflowTitleOCR.isCandidate(duplicateAccount), "Duplicate reserved fields stop the second OCR pass")
        var modelCandidate = profileCandidate; modelCandidate.elements[0].source = "model"
        expect(!WeChatBuiltinWorkflowTitleOCR.isCandidate(modelCandidate), "Candidate gating uses original OCR source only")
        var blockedCandidate = profileCandidate; blockedCandidate.blockingOverlay = true
        expect(!WeChatBuiltinWorkflowTitleOCR.isCandidate(blockedCandidate), "A blocking overlay prevents supplementary profile recognition")
        var chatCopy = profileCandidate; chatCopy.elements.append(profileOCR("chat-title", "文件传输助手", 0.35, 0.065, 0.3, 0.03))
        expect(!WeChatBuiltinWorkflowTitleOCR.isCandidate(chatCopy), "A conversation copying account and About text cannot request profile title recognition")
        var composerCopy = profileCandidate
        composerCopy.elements.append(.init(id: "actual-plus", label: "视觉:添加", rect: .init(x: 0.87, y: 0.88, width: 0.05, height: 0.025), source: "local_visual"))
        expect(!WeChatBuiltinWorkflowTitleOCR.isCandidate(composerCopy), "A current composer symbol excludes a chat from the profile-only second pass")
        let cacheReport = ProcessInfo.processInfo.environment["HARNESS_RUNTIME_CACHE_REPORT"].map { URL(fileURLWithPath: $0) }
        checks += try await HarnessRuntimeCacheChecks.run(directory: directory, reportURL: cacheReport)
        let metricsReport = ProcessInfo.processInfo.environment["HARNESS_RUNTIME_METRICS_REPORT"].map { URL(fileURLWithPath: $0) }
        checks += try await HarnessRuntimeMetricsChecks.run(directory: directory, reportURL: metricsReport)
        checks += try await PilotReplayChecks.run(directory: directory, home: home, search: keyboard)
        print("\(checks) production phone-harness runtime checks passed. Injected OCR and offline input/model probes only; no device or network actions.")
    }
}
