import Foundation

@MainActor final class ChatFixtureTape {
    var frames: [ChatEvidenceFrame]
    var reads = 0
    var scrolls: [ChatReadDirection] = []
    init(_ frames: [ChatEvidenceFrame]) { self.frames = frames }
    func next() throws -> ChatEvidenceFrame {
        guard !frames.isEmpty else { throw AgentError.message("fixture exhausted") }
        reads += 1; return frames.removeFirst()
    }
    func scroll(_ direction: ChatReadDirection) { scrolls.append(direction) }
}

@main struct ChatEvidenceChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
        func rejects(_ body: () throws -> Void, _ message: String) { var failed = false; do { try body() } catch { failed = true }; expect(failed, message) }
        guard CommandLine.arguments.count == 2 else { throw AgentError.message("Expected one explicit offline evidence work directory") }
        let work = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        let replayRoot = work.appendingPathComponent("replay-tmp", isDirectory: true)
        let root = replayRoot.appendingPathComponent("chat-evidence-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var allChecksPassed = false
        defer { if allChecksPassed { try? FileManager.default.removeItem(at: root) } }
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "folder": root.path,
            "replayRoot": replayRoot.path, "work": work.path], options: .sortedKeys)
            .write(to: work.appendingPathComponent("fixture-location.json"), options: .atomic)
        print("ChatEvidence synthetic fixture folder: \(root.path)")
        let target = ChatConversationTarget(stableID: "wechat.builtin.file-transfer", title: "文件传输助手", deviceKey: "fixture-device")
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        var capture = epoch.addingTimeInterval(10000)
        func request(_ id: String, _ count: Int = 6, pages: Int = 100) -> ChatReadRequest {
            ChatReadRequest(scopeID: id, conversation: target, range: .time(start: epoch, end: epoch.addingTimeInterval(Double(count))), maxPages: pages)
        }
        struct Row {
            var text: String
            var time: Date? = nil
            var speaker: String? = "我"
            var media: [ChatUnreadMedia] = []
            var platformID: String? = nil
        }
        func element(_ id: String, _ label: String, _ x: Double, _ y: Double, width: Double = 0.18, source: String = "ocr") -> PhoneUIElement {
            .init(id: id, label: label, rect: .init(x: x - width / 2, y: y - 0.015, width: width, height: 0.03), source: source)
        }
        func frame(_ values: [Row], boundary: Bool = false) throws -> ChatEvidenceFrame {
            capture = capture.addingTimeInterval(1)
            let id = UUID().uuidString
            let rows = values.enumerated().map { index, value in element("bubble-\(index)", value.text, 0.75, 0.32 + Double(index) * 0.06) }
            let proof = element("transfer-proof", "可以在手机和电脑间互传文件", 0.5, 0.22, width: 0.64)
            let snapshot = PhoneUISnapshot(deviceKey: target.deviceKey, scene: "wechat.chat", elements: [
                element("back", "微信", 0.1, 0.08), element("title", target.title, 0.5, 0.08), proof,
                element("input", "发送消息", 0.4, 0.9)
            ] + rows, capturedAt: capture)
            var result = try ChatEvidenceFrame.from(snapshot: snapshot, id: id, reachedBoundary: boundary)
            result.rows = zip(values, rows).map { value, element in
                .init(platformMessageID: value.platformID, speaker: value.speaker, sentAt: value.time,
                    text: value.text, unreadMedia: value.media,
                    anchor: .init(frameID: id, elementIDs: [element.id], rect: element.rect, capturedAt: snapshot.capturedAt))
            }
            return result
        }
        func json(_ claims: [ChatSummaryClaim]) throws -> String {
            struct Envelope: Encodable { var claims: [ChatSummaryClaim] }
            // Optional fields must be present as JSON null in strict model JSON.
            let data = try JSONEncoder().encode(Envelope(claims: claims))
            var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            var values = object["claims"] as! [[String: Any]]
            for i in values.indices { if values[i]["owner"] == nil { values[i]["owner"] = NSNull() }; if values[i]["deadline"] == nil { values[i]["deadline"] = NSNull() } }
            object["claims"] = values
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        func modelInput(_ prompt: String) throws -> ([String: Any], [[String: Any]]) {
            let part = prompt.components(separatedBy: "原消息数据：\n").last!
            let object = try JSONSerialization.jsonObject(with: Data(part.utf8)) as! [String: Any]
            return (object, object["messages"] as! [[String: Any]])
        }
        // Explicit trusted-boundary platform-ID control, not an OCR capability.
        let rows = [Row(text: "先开会讨论", time: epoch), Row(text: "收到"), Row(text: "收到"),
                    Row(text: "张三负责，周五交付", time: epoch.addingTimeInterval(3)),
                    Row(text: "更正：李四负责，周一交付", time: epoch.addingTimeInterval(4)),
                    Row(text: "[图片]", time: epoch.addingTimeInterval(5), media: [.init(kind: .image, label: "[图片]")])].enumerated().map { index, row in
            var value = row; value.platformID = "trusted-control-\(index)"; return value
        }
        let url = root.appendingPathComponent("evidence.json"), store = ChatEvidenceStore(url: url)
        let tape = ChatFixtureTape([try frame(Array(rows[2...])), try frame(Array(rows[..<4]), boundary: true)])
        let session = try await ChatEvidenceReader(store: store).read(request: request("primary"), nextFrame: tape.next, scroll: tape.scroll)
        expect(session.state == .partial, "Unknown timestamps leave the explicit time interval partial while preserving accepted evidence")
        expect(session.messages.count == 6, "Continuous overlap removes only the two shared occurrences")
        expect(session.messages.map { $0.observation.text } == rows.map(\.text), "Chronological order survives older-page prepending")
        expect(session.messages.filter { $0.observation.text == "收到" }.count == 2, "Same text in two messages is preserved")
        expect(Set(session.messages.map(\.id)).count == 6, "Every occurrence gets a distinct session citation ID")
        expect(session.messages[2].anchors.count == 2 && session.messages[3].anchors.count == 2, "Overlap retains both source anchors")
        expect(session.messages[0].observation.sentAt == epoch, "Message time is preserved independently of capture time")
        expect(session.messages[1].observation.sentAt == nil, "Missing message time remains unknown")
        expect(tape.reads == 2 && tape.scrolls == [.older], "Production reader scrolls locally, once between verified pages")
        let restored = ChatEvidenceStore(url: url)
        expect(try restored.session(id: "primary") == session, "Complete raw evidence and order restore from disk")
        rejects({ _ = try restored.prepare(request("primary", 99)) }, "A scope ID cannot silently expand its range")
        var longDevice = request("long-device"); longDevice.conversation.deviceKey = String(repeating: "d", count: 512)
        try longDevice.validate(); expect(true, "Production device descriptor length is accepted")
        var noRange = request("invalid", 0); noRange.range = .latest(count: 0); rejects({ try noRange.validate() }, "Zero count cannot authorize unbounded reading")
        noRange.range = .time(start: epoch, end: epoch.addingTimeInterval(-1)); rejects({ try noRange.validate() }, "Reversed date range is rejected")

        var calls = 0
        let summarizer = ChatEvidenceSummarizer { prompt in
            calls += 1; expect(prompt.count <= 14_000, "Configured model input stays below 14000 characters")
            let (_, values) = try modelInput(prompt)
            let lookup = Dictionary(uniqueKeysWithValues: values.map { ($0["text"] as! String, $0["id"] as! String) }.filter { $0.0 != "收到" })
            return try json([
                .init(category: .fact, statement: "先开会讨论", citations: [.init(messageID: lookup["先开会讨论"]!, quote: "先开会讨论")]),
                .init(category: .task, statement: "原待办：张三负责，周五交付", citations: [.init(messageID: lookup["张三负责，周五交付"]!, quote: "张三负责，周五交付")], owner: "张三", deadline: "周五"),
                .init(category: .correction, statement: "后续更正为李四负责、周一交付", citations: [
                    .init(messageID: lookup["张三负责，周五交付"]!, quote: "张三负责，周五交付"),
                    .init(messageID: lookup["更正：李四负责，周一交付"]!, quote: "更正：李四负责，周一交付")], owner: "李四", deadline: "周一"),
                .init(category: .inference, statement: "可能需要再次确认排期", citations: [.init(messageID: lookup["更正：李四负责，周一交付"]!, quote: "更正：李四负责，周一交付")])
            ])
        }
        let report = try await summarizer.summarize(sessionID: "primary", store: restored)
        expect(calls == 1 && report.claims.count == 4, "One production model batch validates and saves grounded claims")
        expect(report.claims[1].deadline == "周五" && report.claims[2].deadline == "周一", "Earlier commitment and correction keep their order")
        expect(report.markdown().contains("模型推断（非明确承诺）"), "Inference is rendered separately from explicit tasks")
        expect(report.markdown().contains("未处理媒介：image"), "Unread image is listed explicitly")
        expect(report.markdown().contains("绝对发送时间未知"), "Unknown times are disclosed")
        expect(try JSONDecoder().decode(ChatSummaryReport.self, from: JSONEncoder().encode(report)) == report, "Report has a complete JSON export")
        _ = try await summarizer.summarize(sessionID: "primary", store: restored)
        expect(calls == 1, "Repeated summarization reuses saved evidence segments without a model call")
        expect(try ChatEvidenceStore(url: url).session(id: "primary").reports.count == 2, "Validated reports persist with their segments")

        var bad = report.claims[0]; bad.citations[0].messageID = "missing"
        rejects({ try ChatEvidenceSummarizer.validate(claims: [bad], messages: session.messages) }, "Invented message references are rejected")
        bad = report.claims[0]; bad.citations[0].quote = "不存在的承诺"
        rejects({ try ChatEvidenceSummarizer.validate(claims: [bad], messages: session.messages) }, "Invented quotes are rejected")
        bad = report.claims[2]; bad.citations.reverse()
        rejects({ try ChatEvidenceSummarizer.validate(claims: [bad], messages: session.messages) }, "Correction citations cannot reverse source order")
        bad = report.claims[0]; bad.owner = "王五"
        rejects({ try ChatEvidenceSummarizer.validate(claims: [bad], messages: session.messages) }, "An owner absent from cited text is rejected")
        bad = report.claims[0]; bad.deadline = "2026年12月1日"
        rejects({ try ChatEvidenceSummarizer.validate(claims: [bad], messages: session.messages) }, "Unstated absolute deadline is rejected")
        bad = report.claims[0]; bad.category = .inference; bad.owner = "先开会讨论"
        rejects({ try ChatEvidenceSummarizer.validate(claims: [bad], messages: session.messages) }, "An inference cannot be promoted to an owner commitment")
        bad = .init(category: .fact, statement: "图片包含已通过的预算", citations: [.init(messageID: session.messages[5].id, quote: "[图片]")])
        rejects({ try ChatEvidenceSummarizer.validate(claims: [bad], messages: session.messages) }, "Unread media cannot substantiate any content conclusion")

        let ambiguousStore = ChatEvidenceStore(url: root.appendingPathComponent("ambiguous.json"))
        let ambiguousTape = ChatFixtureTape([try frame([Row(text: "收到")]), try frame([Row(text: "收到"), Row(text: "下一项")])])
        var ambiguousFailed = false
        do { _ = try await ChatEvidenceReader(store: ambiguousStore).read(request: request("ambiguous", 5), nextFrame: ambiguousTape.next, scroll: ambiguousTape.scroll) }
        catch ChatEvidenceError.ambiguousContinuity { ambiguousFailed = true }
        expect(ambiguousFailed, "A single same-text GUI bubble cannot prove continuity")
        let ambiguity = try ambiguousStore.session(id: "ambiguous")
        expect(ambiguity.messages.count == 1 && ambiguity.frames.count == 1 && ambiguity.unmergedBatches?.count == 1 && ambiguity.state == .ambiguous, "Ambiguous raw batch persists without fabricated message identity or silent data loss")
        expect(try ChatEvidenceStore(url: root.appendingPathComponent("ambiguous.json")).session(id: "ambiguous").state == .ambiguous, "Ambiguity survives restart")
        let repeatedStore = ChatEvidenceStore(url: root.appendingPathComponent("repeated-sequence.json"))
        let repeatTape = ChatFixtureTape([try frame([Row(text: "A"), Row(text: "B"), Row(text: "A"), Row(text: "B")]), try frame([Row(text: "A"), Row(text: "B"), Row(text: "C")])])
        var repeatFailed = false
        do { _ = try await ChatEvidenceReader(store: repeatedStore).read(request: request("repeated", 9), direction: .newer, nextFrame: repeatTape.next, scroll: repeatTape.scroll) } catch ChatEvidenceError.ambiguousContinuity { repeatFailed = true }
        expect(repeatFailed, "A repeated two-message sequence is not a unique continuity anchor")

        let platformStore = ChatEvidenceStore(url: root.appendingPathComponent("platform.json"))
        let platformTape = ChatFixtureTape([try frame([Row(text: "收到", platformID: "p1")]), try frame([Row(text: "收到", platformID: "p1"), Row(text: "收到", platformID: "p2")], boundary: true)])
        let platform = try await ChatEvidenceReader(store: platformStore).read(request: request("platform", 2), direction: .newer, nextFrame: platformTape.next, scroll: platformTape.scroll)
        expect(platform.messages.count == 2 && platform.messages[0].observation.text == platform.messages[1].observation.text, "Real distinct platform IDs preserve equal text while overlapping one ID")

        let wrongStore = ChatEvidenceStore(url: root.appendingPathComponent("wrong.json"))
        var wrong = try frame([Row(text: "不得读取的其他会话")]); wrong.conversation.stableID = "someone-else"
        let wrongTape = ChatFixtureTape([wrong])
        var wrongFailed = false
        do { _ = try await ChatEvidenceReader(store: wrongStore).read(request: request("wrong"), nextFrame: wrongTape.next, scroll: wrongTape.scroll) } catch ChatEvidenceError.wrongConversation { wrongFailed = true }
        expect(wrongFailed && wrongTape.scrolls.isEmpty, "Wrong stable conversation stops before scrolling")
        expect(try wrongStore.session(id: "wrong").frames.isEmpty, "Wrong conversation messages never enter the saved evidence corpus")
        var unproven = try frame([Row(text: "hello")]); unproven.snapshot.elements.removeAll { $0.id == "transfer-proof" }
        rejects({ _ = try ChatEvidenceFrame.from(snapshot: unproven.snapshot) }, "A matching display title alone cannot establish a stable conversation")
        var badAnchor = try frame([Row(text: "hello")]); badAnchor.rows[0].anchor.elementIDs = ["missing"]
        rejects({ try badAnchor.validate(for: target) }, "Missing source anchors cannot become evidence")
        var overlay = try frame([Row(text: "hello")]); overlay.snapshot.blockingOverlay = true
        rejects({ try overlay.validate(for: target) }, "An overlay obscuring identity stops reads")

        let dateStore = ChatEvidenceStore(url: root.appendingPathComponent("dates.json"))
        var dateRequest = request("dates"); dateRequest.range = .time(start: epoch, end: epoch.addingTimeInterval(20))
        let dateTape = ChatFixtureTape([try frame(Array(rows[..<4]), boundary: true)])
        let dates = try await ChatEvidenceReader(store: dateStore).read(request: dateRequest, nextFrame: dateTape.next, scroll: dateTape.scroll)
        expect(dates.selectedMessages.count == 2 && dates.messages.count == 4, "Unknown message time is preserved but excluded from a specific date range")
        expect(dates.state == .partial, "Unknown dates prevent a claim that the time range is complete")
        let emptySummary = ChatEvidenceSummarizer { _ in "{\"claims\":[]}" }
        let dateReport = try await emptySummary.summarize(sessionID: "dates", store: dateStore)
        expect(dateReport.warnings.contains(where: { $0.contains("未纳入指定日期范围") }), "Date exclusions are explicit in the report")

        let incrementURL = root.appendingPathComponent("increment.json"), incrementStore = ChatEvidenceStore(url: incrementURL)
        let incrementRequest = request("increment", 1000, pages: 1)
        let firstTape = ChatFixtureTape([try frame(Array(rows[..<4]), boundary: true)])
        let first = try await ChatEvidenceReader(store: incrementStore).read(request: incrementRequest, nextFrame: firstTape.next, scroll: firstTape.scroll)
        var incrementCalls = 0, newInputCounts: [Int] = []
        let incrementalSummarizer = ChatEvidenceSummarizer { prompt in
            incrementCalls += 1
            let (object, values) = try modelInput(prompt), newIDs = object["newMessageIDs"] as! [String]
            newInputCounts.append(newIDs.count)
            let newValues = values.filter { newIDs.contains($0["id"] as! String) }
            if incrementCalls == 1 {
                return try json(newValues.map { .init(category: .fact, statement: $0["text"] as! String, citations: [.init(messageID: $0["id"] as! String, quote: $0["text"] as! String)]) })
            }
            let old = values.first { $0["text"] as? String == "张三负责，周五交付" }!, corrected = newValues[0]
            return try json([.init(category: .correction, statement: "负责人及期限已更正", citations: [
                .init(messageID: old["id"] as! String, quote: old["text"] as! String),
                .init(messageID: corrected["id"] as! String, quote: corrected["text"] as! String)])])
        }
        _ = try await incrementalSummarizer.summarize(sessionID: "increment", store: incrementStore)
        let resumed = ChatEvidenceStore(url: incrementURL)
        let secondTape = ChatFixtureTape([try frame(Array(rows[2...]), boundary: true)])
        let second = try await ChatEvidenceReader(store: resumed).read(request: incrementRequest, direction: .newer, nextFrame: secondTape.next, scroll: secondTape.scroll)
        expect(Array(second.messages.prefix(4)).map(\.id) == first.messages.map(\.id), "Restart and incremental overlap preserve prior citation identity")
        expect(second.messages.count == 6, "Incremental reader promotes only the two new occurrences")
        let incrementalReport = try await incrementalSummarizer.summarize(sessionID: "increment", store: resumed)
        expect(incrementCalls == 2 && newInputCounts == [2, 2], "Incremental model work sends only newly accepted in-range messages, never unknown-date rows")
        expect(incrementalReport.claims.contains(where: { $0.category == .correction && $0.citations.count == 2 }), "Cross-batch correction cites old saved evidence and the new correction")
        expect(try resumed.session(id: "increment").summaries.count == 2, "Incremental segment summaries remain saved separately")

        let batchStore = ChatEvidenceStore(url: root.appendingPathComponent("batches.json"))
        let many = (0..<63).map { Row(text: "事项 \($0)", time: epoch.addingTimeInterval(Double($0)), platformID: "batch-\($0)") }
        var pages: [ChatEvidenceFrame] = []
        for start in stride(from: 0, to: 61, by: 2) { pages.append(try frame(Array(many[start..<min(start + 4, many.count)]), boundary: start >= 60)) }
        let batchTape = ChatFixtureTape(pages)
        let batchSession = try await ChatEvidenceReader(store: batchStore).read(request: request("batches", 63), direction: .newer, nextFrame: batchTape.next, scroll: batchTape.scroll)
        expect(batchSession.messages.count == 63, "Many local pages form one complete ordered evidence stream")
        var batchCalls = 0, failBatchTwo = true
        let batchSummarizer = ChatEvidenceSummarizer { prompt in
            batchCalls += 1
            expect(prompt.count <= 14_000, "Every long-chat model batch respects the configured input bound")
            let (object, values) = try modelInput(prompt), ids = object["newMessageIDs"] as! [String]
            if batchCalls == 2 && failBatchTwo { throw AgentError.message("fixture provider interrupted") }
            return try json(values.filter { ids.contains($0["id"] as! String) }.map {
                .init(category: .fact, statement: $0["text"] as! String, citations: [.init(messageID: $0["id"] as! String, quote: $0["text"] as! String)])
            })
        }
        var batchInterrupted = false
        do { _ = try await batchSummarizer.summarize(sessionID: "batches", store: batchStore) } catch { batchInterrupted = true }
        expect(try batchInterrupted && batchStore.session(id: "batches").summaries.count == 1, "A failed later model batch retains the first validated segment")
        failBatchTwo = false
        let batchRestored = ChatEvidenceStore(url: root.appendingPathComponent("batches.json"))
        let batchReport = try await batchSummarizer.summarize(sessionID: "batches", store: batchRestored)
        expect(batchCalls == 4 && batchReport.segmentIDs.count == 3, "Restart summarizes the remaining two batches without replaying the first batch")
        expect(batchReport.messageIDs.count == 63 && batchReport.claims.count == 63, "Long-chat report covers every selected message and validated segment")
        expect(batchReport.claims.first?.statement == "事项 0" && batchReport.claims.last?.statement == "事项 62", "Model batch assembly preserves full message order")

        var extracted = try frame([Row(text: "占位")]).snapshot
        extracted.elements.removeAll { $0.id.hasPrefix("bubble-") }
        extracted.elements += [element("date", "2023年11月15日 08:00", 0.5, 0.32), element("voice", "5″", 0.75, 0.4), element("body", "按原计划", 0.75, 0.48)]
        let parsed = try ChatEvidenceFrame.from(snapshot: extracted, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
        expect(parsed.rows.count == 2 && parsed.rows[0].unreadMedia.first?.kind == .voice, "Production OCR adapter separates date labels and recognizes unread voice duration")
        expect(parsed.rows[1].sentAt != nil && parsed.rows[1].timeLabel == "2023年11月15日 08:00", "Explicit absolute local date is parsed only with a known year and time zone")
        extracted.elements[extracted.elements.firstIndex { $0.id == "date" }!].label = "昨天 10:00"
        let relative = try ChatEvidenceFrame.from(snapshot: extracted)
        expect(relative.rows[1].sentAt == nil && relative.rows[1].timeLabel == "昨天 10:00", "Relative date label is kept without fabricating an absolute message time")

        // The live adapter uses actual production OCR parsing on every frame.
        // Only the first screen contains the independent identity explanation.
        let boundURL = root.appendingPathComponent("bound-identity.json"), boundStore = ChatEvidenceStore(url: boundURL)
        let boundFirst = try frame([Row(text: "A"), Row(text: "B"), Row(text: "C"), Row(text: "D")])
        var boundNext = try frame([Row(text: "E"), Row(text: "F"), Row(text: "A"), Row(text: "B")], boundary: true)
        boundNext.snapshot.elements.removeAll { $0.id == "transfer-proof" }
        rejects({ _ = try ChatEvidenceFrame.from(snapshot: boundNext.snapshot) }, "The standalone OCR factory still rejects a title-only chat frame")
        let liveAdapter = ChatEvidenceCaptureAdapter(), captureID = UUID()
        var boundSnapshots = [boundFirst, boundNext], controlledScrolls = 0
        var boundRejected = false
        do { _ = try await ChatEvidenceReader(store: boundStore).read(request: request("bound", 6), nextObservation: {
            let value = boundSnapshots.removeFirst()
            return try liveAdapter.observation(snapshot: value.snapshot, captureSessionID: captureID, id: value.id, reachedBoundary: value.reachedBoundary)
        }, scroll: { direction in
            try await liveAdapter.scroll(direction) { _ in controlledScrolls += 1 }
        }) } catch ChatEvidenceError.ambiguousContinuity { boundRejected = true }
        let bound = try boundStore.session(id: "bound")
        expect(boundRejected && controlledScrolls == 1 && bound.messages.count == 4, "OCR continuation stops without independent occurrence IDs")
        expect(bound.frames.count == 1 && bound.unmergedBatches?.count == 1, "Second raw OCR batch is retained without a strong identity proof")
        expect(bound.unmergedBatches?[0].sourceFrameID == bound.frames[0].id && bound.unmergedBatches?[0].captureSessionID == captureID, "Raw batch records requested capture context without inheriting authority")
        expect(try ChatEvidenceStore(url: boundURL).session(id: "bound") == bound, "Accepted and unmerged raw evidence revalidate together on reload")
        // Legacy archive validation remains readable; no live adapter mints it.
        var legacyNext = boundNext
        legacyNext.captureSessionID = captureID
        legacyNext.conversation = .init(stableID: target.stableID, title: target.title, kind: .controlledScroll,
            evidenceElementIDs: bound.frames[0].conversation.evidenceElementIDs.filter { $0 != "transfer-proof" },
            previousFrameID: bound.frames[0].id, scrollDirection: .older)
        let resetAdapter = ChatEvidenceCaptureAdapter()
        rejects({ _ = try resetAdapter.frame(snapshot: boundNext.snapshot, captureSessionID: captureID, id: UUID().uuidString) }, "A fresh/resumed adapter cannot inherit identity authority from saved evidence")

        let refreshedAdapter = ChatEvidenceCaptureAdapter()
        _ = try refreshedAdapter.frame(snapshot: boundFirst.snapshot, captureSessionID: captureID, id: boundFirst.id)
        rejects({ _ = try refreshedAdapter.frame(snapshot: boundNext.snapshot, captureSessionID: captureID, id: boundNext.id) }, "A refresh without one wrapped scroll cannot reuse the old identity")
        var refreshScrollFailed = false
        do { try await refreshedAdapter.scroll(.older) { _ in } } catch { refreshScrollFailed = true }
        expect(refreshScrollFailed, "A failed refresh clears the prior binding before any further scroll")

        let changedCapture = ChatEvidenceCaptureAdapter()
        _ = try changedCapture.frame(snapshot: boundFirst.snapshot, captureSessionID: captureID, id: boundFirst.id)
        try await changedCapture.scroll(.older) { _ in }
        rejects({ _ = try changedCapture.frame(snapshot: boundNext.snapshot, captureSessionID: UUID(), id: boundNext.id) }, "Restarted capture cannot inherit a previous capture stream's identity")
        let changedDevice = ChatEvidenceCaptureAdapter()
        _ = try changedDevice.frame(snapshot: boundFirst.snapshot, captureSessionID: captureID, id: boundFirst.id)
        try await changedDevice.scroll(.older) { _ in }
        var foreignDevice = boundNext.snapshot; foreignDevice.deviceKey = "another-device"
        rejects({ _ = try changedDevice.frame(snapshot: foreignDevice, captureSessionID: captureID, id: boundNext.id) }, "A different device cannot inherit identity even when the message sequence matches")
        let changedTitle = ChatEvidenceCaptureAdapter()
        _ = try changedTitle.frame(snapshot: boundFirst.snapshot, captureSessionID: captureID, id: boundFirst.id)
        try await changedTitle.scroll(.older) { _ in }
        var foreignTitle = boundNext.snapshot; foreignTitle.elements[foreignTitle.elements.firstIndex { $0.id == "title" }!].label = "王伟"
        rejects({ _ = try changedTitle.frame(snapshot: foreignTitle, captureSessionID: captureID, id: boundNext.id) }, "Navigation to a different title revokes the current chat binding")
        let missingAnchors = ChatEvidenceCaptureAdapter()
        _ = try missingAnchors.frame(snapshot: boundFirst.snapshot, captureSessionID: captureID, id: boundFirst.id)
        try await missingAnchors.scroll(.older) { _ in }
        var unrelated = try frame([Row(text: "X"), Row(text: "Y"), Row(text: "Z")]); unrelated.snapshot.elements.removeAll { $0.id == "transfer-proof" }
        rejects({ _ = try missingAnchors.frame(snapshot: unrelated.snapshot, captureSessionID: captureID, id: unrelated.id) }, "Same title without a continuous message anchor cannot continue the binding")
        let wrongDirection = ChatEvidenceCaptureAdapter()
        _ = try wrongDirection.frame(snapshot: boundFirst.snapshot, captureSessionID: captureID, id: boundFirst.id)
        try await wrongDirection.scroll(.newer) { _ in }
        rejects({ _ = try wrongDirection.frame(snapshot: boundNext.snapshot, captureSessionID: captureID, id: boundNext.id) }, "An older-page anchor cannot authorize a continuation after a newer-direction scroll")
        let failedScrollAdapter = ChatEvidenceCaptureAdapter()
        _ = try failedScrollAdapter.frame(snapshot: boundFirst.snapshot, captureSessionID: captureID, id: boundFirst.id)
        var failedScroll = false
        do { try await failedScrollAdapter.scroll(.older) { _ in throw AgentError.message("fixture HID failure") } } catch { failedScroll = true }
        expect(failedScroll, "A failed controlled input propagates its failure")
        rejects({ _ = try failedScrollAdapter.frame(snapshot: boundNext.snapshot, captureSessionID: captureID, id: boundNext.id) }, "Failed scrolling cannot mint identity continuation authority")
        let oneScrollAdapter = ChatEvidenceCaptureAdapter()
        _ = try oneScrollAdapter.frame(snapshot: boundFirst.snapshot, captureSessionID: captureID, id: boundFirst.id)
        try await oneScrollAdapter.scroll(.older) { _ in }
        var secondScrollRejected = false
        do { try await oneScrollAdapter.scroll(.older) { _ in preconditionFailure("Second input cannot be dispatched") } } catch { secondScrollRejected = true }
        expect(secondScrollRejected, "One successful scroll grants exactly one next-frame permit, never a second blind scroll")
        let revokedAdapter = ChatEvidenceCaptureAdapter()
        _ = try revokedAdapter.frame(snapshot: boundFirst.snapshot, captureSessionID: captureID, id: boundFirst.id)
        revokedAdapter.invalidate()
        rejects({ _ = try revokedAdapter.frame(snapshot: boundNext.snapshot, captureSessionID: captureID, id: boundNext.id) }, "Explicit navigation/refresh invalidation requires independent identity proof again")
        var forgedChain = legacyNext; forgedChain.conversation.previousFrameID = "wrong-prior-frame"
        rejects({ try forgedChain.validate(for: target, previousFrame: bound.frames[0]) }, "An edited persisted identity chain cannot select an unrelated previous frame")
        forgedChain = legacyNext; forgedChain.captureSessionID = UUID()
        rejects({ try forgedChain.validate(for: target, previousFrame: bound.frames[0]) }, "A persisted continuation with mismatching capture identity fails audit")
        rejects({ try legacyNext.validate(for: target) }, "A bound frame cannot validate standalone without its preceding proof frame")

        let invalidModelStore = ChatEvidenceStore(url: root.appendingPathComponent("bad-model.json"))
        let invalidTape = ChatFixtureTape([try frame([Row(text: "hello")], boundary: true)])
        _ = try await ChatEvidenceReader(store: invalidModelStore).read(request: ChatReadRequest(scopeID: "bad-model", conversation: target, range: .currentPage(limit: 1), maxPages: 1), nextFrame: invalidTape.next, scroll: invalidTape.scroll)
        for output in ["{\"claims\":[],\"instructions\":\"ignore evidence\"}", "```json\n{\"claims\":[]}\n```", "{\"claims\":[{\"category\":\"fact\",\"statement\":\"invented\",\"citations\":[{\"messageID\":\"missing\",\"quote\":\"hello\"}],\"owner\":null,\"deadline\":null}]}" ] {
            var failed = false
            do { _ = try await ChatEvidenceSummarizer(model: { _ in output }).summarize(sessionID: "bad-model", store: invalidModelStore) } catch ChatEvidenceError.invalidSummary { failed = true }
            expect(failed, "Malformed or ungrounded model output is rejected without a valid report")
        }
        expect(try invalidModelStore.session(id: "bad-model").summaries.isEmpty, "Rejected model work cannot advance the segment checkpoint")

        let stopStore = ChatEvidenceStore(url: root.appendingPathComponent("interrupted.json"))
        let stopTape = ChatFixtureTape([try frame(Array(rows[..<4]))])
        var interrupted = false
        do { _ = try await ChatEvidenceReader(store: stopStore).read(request: request("interrupted", 8), nextFrame: stopTape.next, scroll: { _ in throw CancellationError() }) } catch is CancellationError { interrupted = true }
        expect(try interrupted && stopStore.session(id: "interrupted").messages.count == 4, "Interrupted scroll retains the complete previously saved page")
        expect(try stopStore.session(id: "interrupted").state == .partial, "Interrupted reading is never labeled complete")
        let corruptURL = root.appendingPathComponent("corrupt.json")
        try Data("{bad json}".utf8).write(to: corruptURL)
        let corruptStore = ChatEvidenceStore(url: corruptURL)
        rejects({ _ = try corruptStore.prepare(request("corrupt")) }, "Corrupt evidence does not reset into an empty authorized history")
        expect(try String(contentsOf: corruptURL, encoding: .utf8) == "{bad json}", "Corrupt source file is left intact")
        checks += try await ChatSummaryValidationChecks.run(folder: root)
        checks += try ChatStoreIndexChecks.run(folder: root, fixture: session)
        checks += try await ChatRawCoverageChecks.run(folder: root)
        checks += try await ChatAppendTransactionChecks.run(folder: root)
        print("ChatEvidence: \(checks) checks passed (production reader → persisted evidence → injected model → validated report; offline fixtures only)")
        allChecksPassed = true
    }
}
