import Foundation

/// Actual factory/adapter/Reader/Store replay. Synthetic platform IDs occur
/// only in the explicitly named trusted-boundary controls, never OCR snapshots.
enum ChatRawCoverageChecks {
    @MainActor static func run(folder: URL) async throws -> Int {
        var checks = 0
        func expect(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }
        let target = ChatConversationTarget(stableID: "wechat.builtin.file-transfer", title: "文件传输助手", deviceKey: "raw-coverage-device")
        var pixel = Date(timeIntervalSince1970: 1_900_000_000)
        let capture = UUID(), zone = TimeZone(secondsFromGMT: 0)!
        let date = DateFormatter(); date.locale = Locale(identifier: "zh_CN"); date.timeZone = zone; date.dateFormat = "yyyy年M月d日 HH:mm"
        let start = date.date(from: "2023年11月14日 08:00")!, end = date.date(from: "2023年11月14日 09:00")!
        func element(_ id: String, _ text: String, _ x: Double, _ y: Double, _ width: Double = 0.24) -> PhoneUIElement {
            .init(id: id, label: text, rect: .init(x: x-width/2, y: y-0.012, width: width, height: 0.024), source: "ocr")
        }
        func snapshot(_ texts: [String], intro: Bool = true, time: String? = nil) -> PhoneUISnapshot {
            pixel = pixel.addingTimeInterval(1)
            var elements = [element("back", "微信", 0.1, 0.08, 0.18), element("title", target.title, 0.5, 0.08), element("input", "发送消息", 0.4, 0.9)]
            if intro { elements.append(element("intro", "可以在手机和电脑间互传文件", 0.5, 0.22, 0.64)) }
            if let time { elements.append(element("date", time, 0.5, 0.28, 0.8)) }
            elements += texts.enumerated().map { element("row-\($0.offset)", $0.element, 0.75, 0.36+Double($0.offset)*0.09) }
            return .init(deviceKey: target.deviceKey, scene: "untrusted scene hint", elements: elements, capturedAt: pixel)
        }
        var actual: [[String: Any]] = []
        func persistActual(name: String? = nil, evidence: URL? = nil) throws {
            guard let path = ProcessInfo.processInfo.environment["CHAT_RAW_COVERAGE_REPORT"] else { return }
            let report = URL(fileURLWithPath: path)
            let data = try JSONSerialization.data(withJSONObject: ["offlineOnly":true,"actual":actual], options:[.prettyPrinted,.sortedKeys])
            try data.write(to: report, options:.atomic)
            if let name, let evidence {
                let folder = report.deletingLastPathComponent().appendingPathComponent("after-evidence")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(contentsOf: evidence).write(to: folder.appendingPathComponent(name+".json"), options:.atomic)
            }
        }
        var rawFixture: ChatEvidenceSession?
        var rawStore: ChatEvidenceStore?
        var rawURL: URL?
        for direction in [ChatReadDirection.older, .newer] { for minute in [false, true] {
            let name = "pair-\(direction.rawValue)-\(minute)"
            let a = direction == .older ? ["重复A", "重复B", "现在C"] : ["之前C", "重复A", "重复B"]
            let b = direction == .older ? ["更早X", "重复A", "重复B"] : ["重复A", "重复B", "后来X"]
            var tape = [snapshot(a, time: minute ? "2023年11月14日 08:00" : nil), snapshot(b, intro: false, time: minute ? "2023年11月14日 08:00" : nil)]
            let url = folder.appendingPathComponent(name+".json"), store = ChatEvidenceStore(url: url), adapter = ChatEvidenceCaptureAdapter()
            let request = ChatReadRequest(scopeID: name, conversation: target, range: .time(start: start, end: end), maxPages: 3)
            var reads = 0, scrolls = 0, failed = false
            do { _ = try await ChatEvidenceReader(store: store).read(request: request, direction: direction, nextObservation: {
                let current = tape.removeFirst(); reads += 1
                return try adapter.observation(snapshot: current, captureSessionID: capture, id: name+"-\(reads)", timeZone: zone)
            }, scroll: { direction in try await adapter.scroll(direction) { _ in scrolls += 1 } }) }
            catch ChatEvidenceError.ambiguousContinuity { failed = true }
            let session = try store.session(id: name), raw = session.unmergedBatches![0]
            actual.append(["case": name, "state": session.state.rawValue, "messages": session.messages.count, "frames": session.frames.count,
                "rawBatches": session.unmergedBatches!.count, "rawRows": raw.rows.count, "reads": reads, "scrolls": scrolls,
                "totalOriginalRows": session.frames.flatMap(\.rows).count+session.unmergedBatches!.flatMap(\.rows).count])
            try persistActual(name: name, evidence: url)
            expect(failed && session.state == .ambiguous, "Repeated pair cannot prove occurrence continuity in \(name)")
            expect(session.messages.map { $0.observation.text } == a && session.messages.allSatisfy { $0.anchors.count == 1 }, "No guessed IDs/anchors enter accepted messages")
            expect(session.frames.count == 1 && raw.rows.map(\.text) == b && reads == 2 && scrolls == 1, "Both raw observations are retained and no further input occurs")
            expect(raw.reason == .unverifiedConversationContinuity && raw.requestedConversation == target && raw.scopeID == name && raw.direction == direction, "Unverified batch retains requested tags, not identity proof")
            expect(raw.rows.allSatisfy { $0.platformMessageID == nil }, "Actual OCR parser never receives synthetic platform IDs")
            expect(try ChatEvidenceStore(url: url).session(id: name) == session, "Accepted/raw batch transaction reopens exactly")
            var revoked = false
            do { try await adapter.scroll(direction) { _ in preconditionFailure("No input after unverified observation") } } catch { revoked = true }
            expect(revoked, "Unverified observation revokes the adapter")
            var promptCalls = 0
            let summarizer = ChatEvidenceSummarizer { prompt in
                promptCalls += 1
                let payload = prompt.components(separatedBy: "原消息数据：\n").last!
                let input = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as! [String: Any]
                let messages = input["messages"] as! [[String: Any]]
                expect(messages.map { $0["text"] as! String } == a, "Raw second page is never model evidence")
                return "{\"claims\":[]}"
            }
            if minute {
                let report = try await summarizer.summarize(sessionID:name,store:store)
                expect(promptCalls == 1 && report.messageIDs == session.messages.map(\.id) && report.warnings.contains { $0.contains("未合并") }, "Partial summary cites accepted in-range rows only and discloses raw exclusion")
            } else {
                var unavailable = false
                do { _ = try await summarizer.summarize(sessionID:name,store:store) } catch ChatEvidenceError.invalidSummary { unavailable = true }
                expect(unavailable && promptCalls == 0, "Unknown-date rows and unmerged raw batches are both excluded before model work")
            }
            if rawFixture == nil && minute { rawFixture = try store.session(id: name); rawStore = store; rawURL = url }
        } }

        // The same input can also describe a genuine AB overlap. Without a
        // separate occurrence witness that case must stop just as conservatively.
        expect(try ChatMessageContinuity.overlap(existing: rawFixture!.frames[0].rows, incoming: rawFixture!.unmergedBatches![0].rows, direction: .older) == 2, "Old local-uniqueness rule remains archive-compatible")
        var strictRejected = false
        do { _ = try ChatMessageContinuity.verifiedOccurrenceOverlap(existing: rawFixture!.frames[0].rows, incoming: rawFixture!.unmergedBatches![0].rows, direction: .older) } catch { strictRejected = true }
        expect(strictRejected, "A possible genuine OCR overlap is still unverified, not guessed")

        // Every mutation targets the production Store validator. No rejected
        // save advances the in-memory document or replaces the disk document.
        let good = rawFixture!, store = rawStore!, url = rawURL!, disk = try Data(contentsOf: url)
        func rejects(_ label: String, _ edit: (inout ChatEvidenceSession) -> Void) throws {
            var changed = good; edit(&changed)
            var failed = false; do { try store.save(changed) } catch { failed = true }
            expect(failed, "Reject malformed raw evidence: \(label)")
            expect(try store.session(id: good.id) == good && Data(contentsOf: url) == disk, "Rejected \(label) preserves memory and disk")
        }
        try rejects("unknown raw version") { $0.unmergedBatches![0].version = 2 }
        try rejects("scope change") { $0.unmergedBatches![0].scopeID = "other" }
        try rejects("target title change") { $0.unmergedBatches![0].requestedConversation.title = "同名另一人" }
        try rejects("target stable ID change") { $0.unmergedBatches![0].requestedConversation.stableID = "wechat.account:other" }
        try rejects("target device change") { $0.unmergedBatches![0].requestedConversation.deviceKey = "other" }
        try rejects("observed device change") { $0.unmergedBatches![0].snapshot.deviceKey = "other" }
        try rejects("missing source frame") { $0.unmergedBatches![0].sourceFrameID = "missing" }
        try rejects("raw cannot source raw") { $0.unmergedBatches![0].sourceFrameID = $0.unmergedBatches![0].id }
        try rejects("non-increasing pixel time") { $0.unmergedBatches![0].snapshot.capturedAt = $0.frames[0].snapshot.capturedAt }
        try rejects("duplicate raw ID") { $0.unmergedBatches!.append($0.unmergedBatches![0]) }
        try rejects("raw/frame ID collision") { $0.unmergedBatches![0].id = $0.frames[0].id }
        try rejects("raw/message ID collision") { $0.unmergedBatches![0].id = $0.messages[0].id }
        try rejects("invalid pixel geometry") { $0.unmergedBatches![0].snapshot.elements[0].rect.x = -1 }
        try rejects("duplicate source element ID") { $0.unmergedBatches![0].snapshot.elements.append($0.unmergedBatches![0].snapshot.elements[0]) }
        try rejects("missing anchor source") { $0.unmergedBatches![0].rows[0].anchor.elementIDs = ["missing"] }
        try rejects("duplicated anchor source") { let id = $0.unmergedBatches![0].rows[0].anchor.elementIDs[0]; $0.unmergedBatches![0].rows[0].anchor.elementIDs = [id,id] }
        try rejects("mismatched source rectangle") { $0.unmergedBatches![0].rows[0].anchor.rect.x += 0.001 }
        try rejects("invalid row geometry") { $0.unmergedBatches![0].rows[0].anchor.rect.width = .infinity }
        try rejects("anchor on accepted frame") { $0.unmergedBatches![0].rows[0].anchor.frameID = $0.frames[0].id }
        try rejects("anchor clock differs from raw pixels") { $0.unmergedBatches![0].rows[0].anchor.capturedAt = $0.frames[0].snapshot.capturedAt }
        try rejects("future message timestamp") { $0.unmergedBatches![0].rows[0].sentAt = $0.unmergedBatches![0].snapshot.capturedAt.addingTimeInterval(1) }
        try rejects("raw row order") { $0.unmergedBatches![0].rows.swapAt(0,1) }
        try rejects("raw budget frames plus batches") { value in
            let original = value.unmergedBatches![0]
            value.unmergedBatches = (0..<300).map { index in
                var copy = original; copy.id = "raw-budget-\(index)"
                for row in copy.rows.indices { copy.rows[row].anchor.frameID = copy.id }
                return copy
            }
        }
        try rejects("raw becomes message") { value in
            let row = value.unmergedBatches![0].rows[0]
            value.messages.append(.init(id: "raw-message", observation: row, anchors: [row.anchor]))
        }
        try rejects("accepted message gains raw anchor") { $0.messages[0].anchors.append($0.unmergedBatches![0].rows[1].anchor) }
        try rejects("summary cites raw ID") { value in
            value.summaries[0].claims = [.init(category: .fact, statement: "unverified", citations: [.init(messageID: value.unmergedBatches![0].id, quote: "更早X")])]
        }
        let encodedRaw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(good.unmergedBatches![0])) as! [String: Any]
        expect(encodedRaw["conversation"] == nil && encodedRaw["platformIdentityElementID"] == nil && encodedRaw["requestedConversation"] != nil, "Raw schema contains requested context but no conversation proof")
        var changedRange = good.request; changedRange.range = .latest(count: 99)
        var rangeRejected = false; do { _ = try store.prepare(changedRange) } catch { rangeRejected = true }
        expect(try rangeRejected && store.session(id: good.id) == good, "Scope cannot expand range to consume raw evidence")

        // Independent frame factory plus explicitly injected trusted platform
        // IDs for controls. These IDs are not an available OCR product feature.
        func trustedFrame(_ values: [(String, Date?)], boundary: Bool = false) throws -> ChatEvidenceFrame {
            var frame = try ChatEvidenceFrame.from(snapshot: snapshot(values.map(\.0)), reachedBoundary: boundary, timeZone: zone)
            for index in values.indices {
                frame.rows[index].platformMessageID = "trusted-"+values[index].0
                frame.rows[index].sentAt = values[index].1
            }
            return frame
        }
        let low = start.addingTimeInterval(-3600), middle = start.addingTimeInterval(1800), high = end.addingTimeInterval(3600)
        // Exact counterparts of the before replay use the real absolute/relative
        // OCR date parser, not trusted metadata filled by this test.
        for direction in [ChatReadDirection.older, .newer] {
            let name = "parsed-wrong-side-\(direction.rawValue)", label = direction == .older ? "2023年11月14日 07:00" : "2023年11月14日 10:00"
            let frame = try ChatEvidenceFrame.from(snapshot:snapshot(["范围外消息"],time:label),timeZone:zone)
            let evidenceURL = folder.appendingPathComponent(name+".json"), evidence = ChatEvidenceStore(url:evidenceURL)
            var reads = 0, scrolls = 0
            let result = try await ChatEvidenceReader(store:evidence).read(request:.init(scopeID:name,conversation:target,range:.time(start:start,end:end),maxPages:1),direction:direction,nextFrame:{ reads += 1; return frame },scroll:{_ in scrolls += 1})
            actual.append(["case":name,"state":result.state.rawValue,"selected":result.selectedMessages.count,"reads":reads,"scrolls":scrolls,"boundary":frame.reachedBoundary,"parsedTime":frame.rows[0].sentAt!.timeIntervalSince1970])
            try persistActual(name:name,evidence:evidenceURL)
            expect(frame.rows[0].sentAt == (direction == .older ? low : high) && !frame.reachedBoundary, "Real OCR date parser preserves the exact wrong-side before input")
            expect(result.state == .partial && result.selectedMessages.isEmpty && reads == 1 && scrolls == 0, "Wrong-side first page never proves an unvisited interval complete")
        }
        let relative = try ChatEvidenceFrame.from(snapshot:snapshot(["未知日期文字"],time:"昨天 08:00"),timeZone:zone)
        let relativeURL = folder.appendingPathComponent("parsed-relative-budget.json"), relativeStore = ChatEvidenceStore(url:relativeURL)
        var relativeScrolls = 0
        let relativeSession = try await ChatEvidenceReader(store:relativeStore).read(request:.init(scopeID:"parsed-relative-budget",conversation:target,range:.time(start:start,end:end),maxPages:1),nextFrame:{relative},scroll:{_ in relativeScrolls += 1})
        actual.append(["case":"parsed-relative-budget","state":relativeSession.state.rawValue,"selected":relativeSession.selectedMessages.count,"scrolls":relativeScrolls])
        try persistActual(name:"parsed-relative-budget",evidence:relativeURL)
        expect(relativeSession.state == .partial && relativeSession.selectedMessages.isEmpty && relativeSession.unreadTimeMessageIDs.count == 1 && relativeScrolls == 0, "Actual relative-date input stays excluded/partial without the old final unused scroll")
        for direction in [ChatReadDirection.older, .newer] {
            for mode in ["wrong-side", "inside", "equal-endpoints", "unknown", "conflict", "both-sides", "verified-pages"] {
                let name = "time-\(direction.rawValue)-\(mode)"
                let request = ChatReadRequest(scopeID: name, conversation: target, range: .time(start: start, end: end), maxPages: mode == "wrong-side" ? 1 : 2)
                let url = folder.appendingPathComponent(name+".json"), evidence = ChatEvidenceStore(url: url)
                let values: [[(String, Date?)]]
                switch mode {
                case "wrong-side": values = [[("wrong", direction == .older ? low : high)]]
                case "inside": values = [[("inside", middle)]]
                case "equal-endpoints": values = [[("start", start),("end",end)]]
                case "unknown": values = [[("low",low),("unknown",nil),("high",high)]]
                case "conflict": values = [[("high",high),("low",low)]]
                case "both-sides": values = [[("low",low),("middle",middle),("high",high)]]
                default: values = direction == .older ? [[("middle",middle),("high",high)],[("low",low),("middle",middle)]] : [[("low",low),("middle",middle)],[("middle",middle),("high",high)]]
                }
                var tape = try values.map { try trustedFrame($0, boundary: mode != "verified-pages" && mode != "wrong-side") }, reads = 0, scrolls = 0
                let result = try await ChatEvidenceReader(store: evidence).read(request: request, direction: direction, nextFrame: {
                    reads += 1; return tape.removeFirst()
                }, scroll: { _ in scrolls += 1 })
                actual.append(["case":name,"state":result.state.rawValue,"selected":result.selectedMessages.count,"reads":reads,"scrolls":scrolls,"timeConflict":result.knownTimeOrderConflict])
                try persistActual(name: name, evidence: url)
                let complete = mode == "both-sides" || mode == "verified-pages"
                expect(result.state == (complete ? .complete : .partial), "Time interval requires strict ordered witnesses on both sides: \(name)")
                expect(reads == (mode == "verified-pages" ? 2 : 1) && scrolls == (mode == "verified-pages" ? 1 : 0), "Time boundary never causes an unneeded scroll: \(name)")
                if mode == "conflict" {
                    expect(result.messages.map { $0.observation.text } == ["high","low"] && result.knownTimeOrderConflict, "Timestamp conflict preserves original order and values")
                }
                if mode == "unknown" { expect(result.selectedMessages.isEmpty && result.unreadTimeMessageIDs.count == 1, "Unknown date is never filled from pixel time or included in interval") }
            }
        }
        for pages in [1,2] {
            let name = "budget-\(pages)", evidence = ChatEvidenceStore(url: folder.appendingPathComponent(name+".json"))
            var tape = [try trustedFrame([("A",nil),("B",nil)]),try trustedFrame([("B",nil),("C",nil)])], reads = 0, scrolls = 0
            let result = try await ChatEvidenceReader(store: evidence).read(request: .init(scopeID:name,conversation:target,range:.time(start:start,end:end),maxPages:pages),direction:.newer,nextFrame: {
                reads += 1; return tape.removeFirst()
            },scroll: {_ in scrolls += 1})
            expect(result.state == .partial && reads == pages && scrolls == pages-1, "Final consumed page does not dispatch an unused scroll")
        }

        // Exercise the attach-then-newRows-ID guard, not only a rejected match.
        // The Reader must discard that entire candidate mutation transaction.
        let lateStore = ChatEvidenceStore(url: folder.appendingPathComponent("late-duplicate.json"))
        let lateFirst = try trustedFrame([("A",nil),("B",nil),("C",nil)])
        let lateSecond = try trustedFrame([("C",nil),("A",nil)])
        expect(try ChatMessageContinuity.verifiedOccurrenceOverlap(existing: lateFirst.rows, incoming: lateSecond.rows, direction: .newer) == 1, "Late-duplicate control passes the independent overlap match first")
        var lateTape = [lateFirst,lateSecond], beforeMessages: [ChatEvidenceMessage] = [], lateReads = 0, lateScrolls = 0, lateFailed = false
        do { _ = try await ChatEvidenceReader(store: lateStore).read(request:.init(scopeID:"late-duplicate",conversation:target,range:.time(start:start,end:end),maxPages:3),direction:.newer,nextFrame: {
            lateReads += 1
            if lateReads == 2 { beforeMessages = try lateStore.session(id:"late-duplicate").messages }
            return lateTape.removeFirst()
        },scroll: {_ in lateScrolls += 1}) } catch ChatEvidenceError.ambiguousContinuity { lateFailed = true }
        let late = try lateStore.session(id:"late-duplicate")
        expect(lateFailed && late.messages == beforeMessages && late.messages.allSatisfy { $0.anchors.count == 1 }, "A late duplicate newRows ID cannot leave even one attached candidate anchor")
        expect(late.frames.count == 1 && late.unmergedBatches?.count == 1 && late.unmergedBatches?[0].reason == .unverifiedOccurrenceContinuity && lateReads == 2 && lateScrolls == 1, "Late guard preserves original evidence and stops all further input")
        actual.append(["case":"late-duplicate","state":late.state.rawValue,"anchorsUnchanged":late.messages == beforeMessages,"reads":lateReads,"scrolls":lateScrolls])
        try persistActual(name:"late-duplicate",evidence:folder.appendingPathComponent("late-duplicate.json"))

        let capacityURL = folder.appendingPathComponent("original-capacity.json"), capacityStore = ChatEvidenceStore(url: capacityURL)
        let capacityRequest = ChatReadRequest(scopeID:"original-capacity",conversation:target,range:.time(start:start,end:end),maxPages:2)
        var capacity = ChatEvidenceSession(request:capacityRequest)
        for _ in 0..<299 { capacity.frames.append(try trustedFrame([("A",nil)])) }
        capacity.messages = [.init(id:"capacity-message",observation:capacity.frames[0].rows[0],anchors:capacity.frames.map { $0.rows[0].anchor })]
        try capacityStore.save(capacity)
        let finalCapacityFrame = try trustedFrame([("A",nil),("B",nil)])
        var capacityReads = 0, capacityScrolls = 0
        let full = try await ChatEvidenceReader(store:capacityStore).read(request:capacityRequest,direction:.newer,nextFrame:{
            capacityReads += 1; return finalCapacityFrame
        },scroll:{_ in capacityScrolls += 1})
        expect(full.state == .partial && full.frames.count == 300 && full.messages.count == 2 && capacityReads == 1 && capacityScrolls == 0, "Consuming the last original-evidence slot never dispatches an unused scroll")

        // This immutable fixture was created by the actual pre-fix reader from
        // synthetic OCR frames. It must remain readable, never new authority.
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/legacy-controlled-v1.json")
        let legacyURL = folder.appendingPathComponent("legacy-controlled-v1.json"), legacyBytes = try Data(contentsOf: fixtureURL)
        try legacyBytes.write(to: legacyURL)
        let legacyStore = ChatEvidenceStore(url: legacyURL), legacy = legacyStore.sessions[0]
        expect(legacy.unmergedBatches == nil && legacy.frames.last?.conversation.kind == .controlledScroll && legacy.state == .complete, "Valid old nil-field controlled-scroll archive loads unchanged")
        try legacyStore.save(legacy)
        expect(try Data(contentsOf: legacyURL) == legacyBytes, "Unchanged legacy archive save preserves original bytes and missing optional field")
        var legacyCalls = 0, legacyBlocked = false
        let legacySummarizer = ChatEvidenceSummarizer { _ in legacyCalls += 1; return "{\"claims\":[]}" }
        do { _ = try await legacySummarizer.summarize(sessionID:legacy.id,store:legacyStore) } catch ChatEvidenceError.latestEndUnknown { legacyBlocked = true }
        expect(legacyBlocked && legacyCalls == 0 && legacy.selectedMessages.isEmpty, "Old latest archive remains readable, but cannot authorize new model work")
        expect(try Data(contentsOf:legacyURL) == legacyBytes, "Rejected old latest summary leaves raw history byte-identical")
        let plainA = try ChatEvidenceFrame.from(snapshot:snapshot(["A","B","C"],time:"2023年11月14日 08:00"),timeZone:zone), plainB = try ChatEvidenceFrame.from(snapshot:snapshot(["X","A","B"],time:"2023年11月14日 08:00"),timeZone:zone)
        var plainLegacy = ChatEvidenceSession(request:.init(scopeID:"legacy-independent-pages",conversation:target,range:.time(start:start,end:end),maxPages:2))
        plainLegacy.frames = [plainA,plainB]; plainLegacy.state = .complete
        plainLegacy.messages = [.init(id:"plain-X",observation:plainB.rows[0],anchors:[plainB.rows[0].anchor]),
            .init(id:"plain-A",observation:plainA.rows[0],anchors:[plainA.rows[0].anchor,plainB.rows[1].anchor]),
            .init(id:"plain-B",observation:plainA.rows[1],anchors:[plainA.rows[1].anchor,plainB.rows[2].anchor]),
            .init(id:"plain-C",observation:plainA.rows[2],anchors:[plainA.rows[2].anchor])]
        let plainStore = ChatEvidenceStore(url:folder.appendingPathComponent("legacy-independent-pages.json")); try plainStore.save(plainLegacy)
        let plainReport = try await ChatEvidenceSummarizer { _ in "{\"claims\":[]}" }.summarize(sessionID:plainLegacy.id,store:plainStore)
        expect(plainReport.warnings.contains { $0.contains("旧连续性") }, "Old nil-ID cross-frame associations need a warning even when each frame independently identified the chat")
        try persistActual(name: "legacy-controlled-after-summary", evidence: legacyURL)
        return checks
    }
}
