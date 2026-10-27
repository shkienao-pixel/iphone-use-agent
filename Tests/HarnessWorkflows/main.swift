import Foundation

@MainActor final class WorkflowTape {
    let stream = UUID()
    var queued: [[PhoneUIElement]] = []
    var values: [Date: [PhoneUIElement]] = [:]
    var reads = 0
    func frame(_ elements: [PhoneUIElement], stream: UUID? = nil, at: Date = Date()) -> ScreenFrame {
        let frame = ScreenFrame(capturedAt: at, captureID: stream ?? self.stream)
        values[at] = elements; return frame
    }
    func recognize(_ frame: ScreenFrame) throws -> [PhoneUIElement] { values[frame.capturedAt] ?? [] }
    func next(_ after: Date) throws -> ScreenFrame {
        guard !queued.isEmpty else { throw AgentError.message("fixture exhausted") }
        reads += 1; return frame(queued.removeFirst())
    }
}

@main struct HarnessWorkflowChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        func element(_ id: String, _ label: String, _ x: Double, _ y: Double) -> PhoneUIElement {
            PhoneUIElement(id: id, label: label, rect: PhoneUIRect(x: x - 0.04, y: y - 0.014, width: 0.08, height: 0.028), source: "ocr")
        }
        func decode(_ string: String) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(string.utf8)) as! [String: Any] }
        func snapshot(_ elements: [PhoneUIElement]) -> PhoneUISnapshot {
            PhoneUISnapshot(deviceKey: "fixture", scene: "unknown", elements: elements, capturedAt: Date())
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneWorkflows-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let list = [element("title", "微信", 0.5, 0.08), element("chat-tab", "微信", 0.13, 0.94),
                    element("contacts", "通讯录", 0.38, 0.94), element("discover", "发现", 0.62, 0.94),
                    element("me", "我", 0.87, 0.94), element("assistant", "文件传输助手", 0.32, 0.35)]
        let transferProof = PhoneUIElement(id: "system-transfer", label: "可以在手机和电脑间互传文件", rect: PhoneUIRect(x: 0.18, y: 0.22, width: 0.64, height: 0.04), source: "ocr")
        let header = [element("back", "微信", 0.1, 0.08), element("title", "文件传输助手", 0.5, 0.08), transferProof]
        let empty = header + [element("composer", "发送消息", 0.4, 0.88)]
        let keyboard = [element("space", "空格", 0.5, 0.94), element("return", "换行", 0.89, 0.94)]
        let focused = header + [element("composer", "发送消息", 0.4, 0.61)] + keyboard
        let drafted = header + [element("draft", "hello", 0.4, 0.61), element("send", "发送", 0.9, 0.61)] + keyboard
        let submitted = focused + [element("bubble", "hello", 0.77, 0.46)]
        let search = [element("search", "搜索", 0.4, 0.08), element("cancel", "取消", 0.9, 0.08),
                      element("moments", "朋友圈", 0.2, 0.3), element("articles", "文章", 0.5, 0.3),
                      element("accounts", "公众号", 0.8, 0.3), element("assistant", "文件传输助手", 0.35, 0.48)]
        let moments = [element("back", "发现", 0.12, 0.08), element("title", "朋友圈", 0.5, 0.08), element("album", "我的朋友圈", 0.4, 0.3)]
        let redSearch = [element("brand", "小红书", 0.5, 0.03), element("search", "搜索", 0.4, 0.11), element("cancel", "取消", 0.9, 0.11), element("history", "搜索历史", 0.3, 0.3)]
        let redResults = [element("brand", "小红书", 0.5, 0.06), element("all", "综合", 0.2, 0.2), element("users", "用户", 0.5, 0.2), element("filter", "筛选", 0.9, 0.2)]
        let redNote = [element("brand", "小红书", 0.5, 0.04), element("follow", "关注", 0.9, 0.13), element("comment", "说点什么", 0.3, 0.92)]
        let redComments = redNote + [element("count", "共12条评论", 0.4, 0.35)]
        for (elements, expected) in [(list, "wechat.list"), (search, "wechat.search"), (empty, "wechat.chat"), (moments, "wechat.moments"),
                                     (redSearch, "xiaohongshu.search"), (redResults, "xiaohongshu.results"), (redNote, "xiaohongshu.note"), (redComments, "xiaohongshu.comments")] {
            check(PhonePageAdapters.identity(in: snapshot(elements))?.scene == expected, "Current OCR structure identifies \(expected)")
        }
        check(PhonePageAdapters.identity(in: snapshot([element("search", "搜索", 0.4, 0.08)])) == nil, "Generic search cannot establish app identity")
        check(PhonePageAdapters.identity(in: snapshot(header)) == nil, "Chat title without composer evidence is unknown")
        check(!PhonePageAdapters.selfConversation("王伟"), "Display-name-only people are unsupported rather than guessed")
        let aliases = ["文件传输助手", "File Transfer", "File Transfer Assistant"]
        for expected in aliases {
            for actual in aliases {
                check(PhonePageAdapters.conversationMatches(expected, actual), "Built-in target aliases match independent of display language")
            }
        }
        for (expected, actual) in [("王伟", "王伟"), ("文件传输助手", "王伟"), ("王伟", "File Transfer"),
                                   ("文件传输助手", "File Transfer Assistant 2"), ("filehelper", "File Transfer")] {
            check(!PhonePageAdapters.conversationMatches(expected, actual), "Ordinary people and partial/broader names never become a built-in target")
        }
        check(!PhonePageAdapters.conversationMatches("文件传输助手", nil), "Unknown conversation is never matched")
        let englishRow = list.map { value -> PhoneUIElement in var item = value; if item.id == "assistant" { item.label = "File Transfer" }; return item }
        var englishListSnapshot = snapshot(englishRow); englishListSnapshot.scene = "wechat.list"
        check(PhonePageAdapters.conversationRow("文件传输助手", in: englishListSnapshot)?.id == "assistant", "Chinese target finds a unique English built-in candidate row")
        let twoAliases = englishRow + [element("other-alias", "文件传输助手", 0.35, 0.55)]
        var ambiguousListSnapshot = snapshot(twoAliases); ambiguousListSnapshot.scene = "wechat.list"
        check(PhonePageAdapters.conversationRow("文件传输助手", in: ambiguousListSnapshot) == nil, "Two language aliases remain ambiguous, never selecting one row")
        for json in [#"{"operation":"wechat_send","target":"王伟","text":"hello","operation_id":"task-001"}"#,
                     #"{"operation":"wechat_send","target":"文件传输助手","text":"hello\nworld","operation_id":"task-001"}"#,
                     #"{"operation":"wechat_send","target":"文件传输助手","text":"hello"}"#,
                     #"{"operation":"home","operation_id":"task-001"}"#] {
            do { _ = try PhoneHarnessRequest.decode(json); preconditionFailure("Invalid business request accepted") } catch { checks += 1 }
        }
        let request = try PhoneHarnessRequest.decode(#"{"operation":"wechat_send","target":"文件传输助手","text":"hello","operation_id":"self-hello-001"}"#)
        let tape = WorkflowTape(), executor = MouseExecutor(), url = root.appendingPathComponent("happy.json")
        let runtime = PhoneHarnessRuntime(executor: executor, memoryURL: url, recognize: tape.recognize)
        tape.queued = [empty, focused, drafted, submitted]
        ModelProbe.calls = 0
        let result = try await runtime.execute(request, frame: tape.frame(list), mappedHome: false, nextFrame: tape.next)
        let receipt = try decode(result.summary)
        check(receipt["status"] as? String == "observed_submission", "Macro reaches observed UI submission only after exact draft and new bubble")
        check(executor.actions == [.tap, .tap, .type, .tap], "One semantic command executes four bounded inputs")
        check(tape.reads == 4 && ModelProbe.calls == 0, "Internal workflow uses local verification without remote decisions")
        check(result.verifiedFrame != nil && !result.requiresUserReview && !runtime.hasPendingReview, "Successful UI observation returns real terminal frame without a pending review")
        check(executor.dispatched.filter { $0.kind == .type }.map(\.text) == ["hello"], "Exactly the fixed ASCII text was typed once")
        let journal = try JSONDecoder().decode(PhoneWorkflowJournal.self, from: Data(contentsOf: url.deletingPathExtension().appendingPathExtension("workflows.json")))
        check(journal.record(id: request.operationID!)?.stage == .observedOnce, "Verified terminal stage persists on disk")
        let restoredExecutor = MouseExecutor(), restored = PhoneHarnessRuntime(executor: restoredExecutor, memoryURL: url, recognize: tape.recognize)
        let duplicate = try await restored.execute(request, frame: tape.frame(submitted), mappedHome: false, nextFrame: tape.next)
        check(try decode(duplicate.summary)["status"] as? String == "previously_observed_submission", "Restart returns durable prior result")
        check(restoredExecutor.actions.isEmpty && duplicate.verifiedFrame == nil, "Repeated operation does not replay any input or invent new proof")
        var alternateID = request; alternateID.operationID = "observed-new-id-bypass"; alternateID.target = "file transfer assistant"
        let sameTask = try await restored.execute(alternateID, frame: tape.frame(submitted), mappedHome: false, nextFrame: tape.next)
        check(try decode(sameTask.summary)["status"] as? String == "previously_observed_submission" && restoredExecutor.actions.isEmpty, "A different operation ID and target alias cannot repeat observed content in the same host task")

        // Cross-language matching never relaxes the independent built-in proof,
        // exact draft, current controls, or post-send observation requirements.
        let englishTransferProof = PhoneUIElement(id: "system-transfer", label: "You can transfer files between your phone and computer.", rect: PhoneUIRect(x: 0.18, y: 0.22, width: 0.64, height: 0.04), source: "ocr")
        let englishHeader = [element("back", "微信", 0.1, 0.08), element("title", "File Transfer", 0.5, 0.08), englishTransferProof]
        let englishEmpty = englishHeader + [element("composer", "发送消息", 0.4, 0.88)]
        let englishFocused = englishHeader + [element("composer", "发送消息", 0.4, 0.61)] + keyboard
        let englishDrafted = englishHeader + [element("draft", "hello", 0.4, 0.61), element("send", "发送", 0.9, 0.61)] + keyboard
        let englishSubmitted = englishFocused + [element("bubble", "hello", 0.77, 0.46)]
        let aliasTape = WorkflowTape(), aliasExecutor = MouseExecutor()
        let aliasRuntime = PhoneHarnessRuntime(executor: aliasExecutor, memoryURL: root.appendingPathComponent("alias.json"), recognize: aliasTape.recognize)
        aliasTape.queued = [englishEmpty, englishFocused, englishDrafted, englishSubmitted]
        let aliasReceipt = try await aliasRuntime.execute(request, frame: aliasTape.frame(englishRow), mappedHome: false, nextFrame: aliasTape.next)
        check(try decode(aliasReceipt.summary)["status"] as? String == "observed_submission", "Chinese request and English page complete only with built-in proof and visible result")
        check(aliasExecutor.actions == [.tap, .tap, .type, .tap], "Cross-language workflow dispatches one exact bounded input sequence")
        let spoofTape = WorkflowTape(), spoofExecutor = MouseExecutor()
        let spoof = PhoneHarnessRuntime(executor: spoofExecutor, memoryURL: root.appendingPathComponent("alias-spoof.json"), recognize: spoofTape.recognize)
        spoofTape.queued = [englishEmpty.filter { $0.id != "system-transfer" }]
        let spoofResult = try await spoof.execute(request, frame: spoofTape.frame(englishRow), mappedHome: false, nextFrame: spoofTape.next)
        check(spoofResult.requiresUserReview && spoofExecutor.actions == [.tap], "English-lookalike contact without built-in proof stops before focus, input, or send")
        let duplicateAliasTape = WorkflowTape(), duplicateAliasExecutor = MouseExecutor()
        let duplicateAlias = PhoneHarnessRuntime(executor: duplicateAliasExecutor, memoryURL: root.appendingPathComponent("alias-ambiguous.json"), recognize: duplicateAliasTape.recognize)
        let duplicateAliasResult = try await duplicateAlias.execute(request, frame: duplicateAliasTape.frame(twoAliases), mappedHome: false, nextFrame: duplicateAliasTape.next)
        check(duplicateAliasResult.requiresUserReview && duplicateAliasExecutor.actions.isEmpty, "Ambiguous cross-language rows cause no click or input")

        // A moved target is resolved from current content and bounds, never its old row.
        for (name, rows, y) in [("scroll", list.filter { $0.id != "assistant" } + [element("assistant", "文件传输助手", 0.32, 0.71)], 0.71),
                                ("insertion", list.filter { $0.id != "assistant" } + [element("new", "新联系人", 0.32, 0.35), element("assistant", "文件传输助手", 0.32, 0.49)], 0.49)] {
            let movingTape = WorkflowTape(), movingExecutor = MouseExecutor()
            let moving = PhoneHarnessRuntime(executor: movingExecutor, memoryURL: root.appendingPathComponent(name + ".json"), recognize: movingTape.recognize)
            movingTape.queued = [empty, focused, drafted, submitted]
            _ = try await moving.execute(request, frame: movingTape.frame(rows), mappedHome: false, nextFrame: movingTape.next)
            check(abs(movingExecutor.dispatched.first!.y! - y) < 0.0001, "\(name) selects current target rectangle")
        }
        let duplicateTape = WorkflowTape(), duplicateExecutor = MouseExecutor()
        let duplicateRuntime = PhoneHarnessRuntime(executor: duplicateExecutor, memoryURL: root.appendingPathComponent("same-name.json"), recognize: duplicateTape.recognize)
        let sameNames = list + [element("other", "文件传输助手", 0.35, 0.55)]
        let ambiguous = try await duplicateRuntime.execute(request, frame: duplicateTape.frame(sameNames), mappedHome: false, nextFrame: duplicateTape.next)
        check(try decode(ambiguous.summary)["status"] as? String == "partial_pending_review" && duplicateExecutor.actions.isEmpty, "Same-name rows cannot choose an arbitrary identity")

        for (name, sequence, expected) in [
            ("same-name-contact", [empty.filter { $0.id != "system-transfer" }], [AgentAction.Kind.tap]),
            ("focus-change", [empty, header + keyboard], [AgentAction.Kind.tap, .tap]),
            ("popup", [empty, focused + [element("dialog", "允许", 0.5, 0.45)]], [.tap, .tap]),
            ("wrong-chat", [header.map { value in var value = value; if value.id == "title" { value.label = "王伟" }; return value } + [element("composer", "发送消息", 0.4, 0.88)]], [.tap]),
            ("input-unknown", [empty, focused, focused], [.tap, .tap, .type]),
            ("submit-unknown", [empty, focused, drafted, drafted], [.tap, .tap, .type, .tap]),
            ("duplicate-bubbles", [empty, focused, drafted, submitted + [element("bubble2", "hello", 0.77, 0.35)]], [.tap, .tap, .type, .tap]),
            ("scrolled-old-bubble", [empty, focused, drafted, submitted.filter { $0.id != "system-transfer" }], [.tap, .tap, .type, .tap])
        ] {
            let faultTape = WorkflowTape(), faultExecutor = MouseExecutor(), faultURL = root.appendingPathComponent(name + ".json")
            let fault = PhoneHarnessRuntime(executor: faultExecutor, memoryURL: faultURL, recognize: faultTape.recognize)
            faultTape.queued = sequence
            let first = try await fault.execute(request, frame: faultTape.frame(list), mappedHome: false, nextFrame: faultTape.next)
            check(try decode(first.summary)["status"] as? String == "partial_pending_review" && first.verifiedFrame == nil && first.requiresUserReview && fault.hasPendingReview, "\(name) returns explicit partial without reusable proof")
            check(faultExecutor.actions == expected, "\(name) stops at the first missing/changed precondition")
            let resumedExecutor = MouseExecutor(), resumed = PhoneHarnessRuntime(executor: resumedExecutor, memoryURL: faultURL, recognize: faultTape.recognize)
            let pending = try await resumed.execute(request, frame: faultTape.frame(submitted), mappedHome: false, nextFrame: faultTape.next)
            check(try decode(pending.summary)["status"] as? String == "pending_review" && resumedExecutor.actions.isEmpty, "\(name) restart never replays partial input or sending")
            var newID = request; newID.operationID = "new-id-cannot-retry"
            do { _ = try await resumed.execute(newID, frame: faultTape.frame(submitted), mappedHome: false, nextFrame: faultTape.next); preconditionFailure("Pending fingerprint bypassed with new ID") }
            catch is PhoneHarnessFallback { checks += 1 }
            check(resumedExecutor.actions.isEmpty, "\(name) new ID does not bypass pending receipt")
            for alias in ["File Transfer Assistant", "file transfer assistant", "File Transfer", "文件传输助手"] {
                var aliasRequest = newID; aliasRequest.target = alias
                do { _ = try await resumed.execute(aliasRequest, frame: faultTape.frame(submitted), mappedHome: false, nextFrame: faultTape.next); preconditionFailure("Alias bypassed pending fingerprint") }
                catch is PhoneHarnessFallback { checks += 1 }
            }
            check(resumedExecutor.actions.isEmpty, "\(name) all self-conversation aliases share the same pending business identity")
            do { _ = try await resumed.execute(PhoneHarnessRequest(operation: .tap, target: "文件传输助手"), frame: faultTape.frame(list), mappedHome: false, nextFrame: faultTape.next); preconditionFailure("Generic tap bypassed pending review") }
            catch is PhoneHarnessFallback { checks += 1 }
            try resumed.resolveReviewed(operationID: request.operationID!, resolution: .confirmedNotSubmitted)
            check(!resumed.hasPendingReview && resumed.pendingWorkflowRecords.isEmpty && resumedExecutor.actions.isEmpty, "\(name) explicit human review resolves state without any automatic retry")
            let review = try await resumed.execute(request, frame: faultTape.frame(list), mappedHome: false, nextFrame: faultTape.next)
            check(try decode(review.summary)["stage"] as? String == "reviewedByUser" && resumedExecutor.actions.isEmpty && !review.requiresUserReview, "\(name) human review is distinguished from OCR success and never replays the operation")
            if name == "submit-unknown" {
                resumed.taskScopeID = UUID()
                faultTape.queued = [empty, focused, drafted, submitted]
                let newTask = try await resumed.execute(newID, frame: faultTape.frame(list), mappedHome: false, nextFrame: faultTape.next)
                check(try decode(newTask.summary)["status"] as? String == "observed_submission", "After explicit not-submitted review, a separately started task may execute a new operation")
                check(resumedExecutor.actions == [.tap, .tap, .type, .tap], "A reviewed record neither auto-retries nor permanently blocks an independent authorized task")
            }
        }
        let staleTape = WorkflowTape(), staleExecutor = MouseExecutor()
        let stale = PhoneHarnessRuntime(executor: staleExecutor, memoryURL: root.appendingPathComponent("stale.json"), recognize: staleTape.recognize)
        let beforeFrame = staleTape.frame(list)
        let context = try decode(await stale.context(for: beforeFrame))
        let advertised = (context["elements"] as! [[String: String]]).first { $0["label"] == "文件传输助手" }!["id"]!
        let movedFrame = staleTape.frame(list.filter { $0.id != "assistant" } + [element("other", "其他联系人", 0.32, 0.35)])
        do { _ = try await stale.execute(PhoneHarnessRequest(operation: .tap, target: advertised), frame: movedFrame, mappedHome: false, nextFrame: staleTape.next); preconditionFailure("Old observation ID reused") }
        catch is PhoneHarnessFallback { checks += 1 }
        check(staleExecutor.actions.isEmpty, "An old element ID cannot select a new row at the same point")
        let cachedContext = try decode(await stale.context(for: beforeFrame))
        check((cachedContext["elements"] as! [[String: String]]).contains { $0["id"] == advertised }, "The identical captured pixel frame retains its element identity")
        do { _ = try await stale.context(for: staleTape.frame(list, at: Date().addingTimeInterval(-10))); preconditionFailure("Stale observation accepted") }
        catch is PhoneHarnessFallback { checks += 1 }
        let corruptURL = root.appendingPathComponent("corrupt.json")
        try Data("broken".utf8).write(to: corruptURL.deletingPathExtension().appendingPathExtension("workflows.json"))
        let corrupt = PhoneHarnessRuntime(executor: staleExecutor, memoryURL: corruptURL, recognize: staleTape.recognize)
        do { _ = try await corrupt.execute(request, frame: staleTape.frame(list), mappedHome: false, nextFrame: staleTape.next); preconditionFailure("Corrupt journal allowed sending") }
        catch is PhoneHarnessFallback { checks += 1 }
        check(staleExecutor.actions.isEmpty, "Corrupt persistent state fails closed before dispatch")
        check(corrupt.hasPendingReview, "Corrupt storage also blocks the outer engine from new GUI tasks")
        let slowTape = WorkflowTape(), slowExecutor = MouseExecutor()
        let slow = PhoneHarnessRuntime(executor: slowExecutor, memoryURL: root.appendingPathComponent("slow-ocr.json"), recognize: { frame in
            try await Task.sleep(nanoseconds: 1_600_000_000)
            return try slowTape.recognize(frame)
        })
        do { _ = try await slow.execute(request, frame: slowTape.frame(list), mappedHome: false, nextFrame: slowTape.next); preconditionFailure("OCR completed on stale frame but dispatched") }
        catch is PhoneHarnessFallback { checks += 1 }
        check(slowExecutor.actions.isEmpty, "OCR completion rechecks freshness before any dispatch")
        let switchedTape = WorkflowTape(), switchedExecutor = MouseExecutor(), switchedURL = root.appendingPathComponent("switch.json")
        let switched = PhoneHarnessRuntime(executor: switchedExecutor, memoryURL: switchedURL, recognize: switchedTape.recognize)
        let switchedReceipt = try await switched.execute(request, frame: switchedTape.frame(list), mappedHome: false, nextFrame: { _ in switchedTape.frame(empty, stream: UUID()) })
        check(switchedReceipt.requiresUserReview && switchedExecutor.actions == [.tap], "Sharing changed after opening stops before focus and leaves a structured pending receipt")
        print("\(checks) production page/workflow checks passed. Synthetic OCR and offline input only; no real WeChat/Xiaohongshu, real OCR, Bluetooth, sending, delivery, device speed or full task acceptance was tested.")
    }
}
