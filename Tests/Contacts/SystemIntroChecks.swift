import Foundation

/// Uses the production profile navigation, reader, store and strict summarizer.
/// OCR/control observations and the echo closure are synthetic offline inputs.
enum SystemIntroChecks {
    @MainActor static func run(folder: URL) async throws -> Int {
        var checks = 0, failures: [String] = [], actual: [[String: Any]] = []
        func expect(_ ok: Bool, _ label: String) { checks += 1; if !ok { failures.append(label) } }
        func publish() throws {
            guard let path = ProcessInfo.processInfo.environment["CHAT_SYSTEM_INTRO_REPORT"] else { return }
            let output = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["offlineOnly": true, "checks": checks, "failures": failures, "actual": actual], options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        }
        func preserve(_ source: URL, _ name: String) throws {
            guard let path = ProcessInfo.processInfo.environment["CHAT_SYSTEM_INTRO_REPORT"] else { return }
            let output = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("after-evidence")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try Data(contentsOf: source).write(to: output.appendingPathComponent(name + ".json"), options: .atomic)
        }
        let phrase = "可以在手机和电脑间互传文件", note = "Synthetic note one"
        let helper = ChatConversationTarget(stableID: "wechat.builtin.file-transfer", title: "文件传输助手", deviceKey: "synthetic-fixture-device")
        let ordinary = ChatConversationTarget(stableID: "wechat.account:wxid_intro_fixture", title: "合成联系人", deviceKey: helper.deviceKey)
        var ordinaryAlias = ordinary; ordinaryAlias.title = helper.title
        var pixel = Date(timeIntervalSince1970: 1_800_100_000)
        func element(_ id: String, _ label: String, _ x: Double, _ y: Double, _ width: Double = 0.18, source: String = "ocr") -> PhoneUIElement {
            .init(id: id, label: label, rect: .init(x: x - width / 2, y: y - 0.015, width: width, height: 0.03), source: source)
        }
        func observe(_ elements: [PhoneUIElement], _ stream: UUID) -> WeChatConversationObservation {
            pixel = pixel.addingTimeInterval(1)
            return .init(snapshot: .init(deviceKey: helper.deviceKey, scene: "untrusted scene", elements: elements, capturedAt: pixel), captureSessionID: stream, frameID: UUID().uuidString)
        }
        func profile(_ target: ChatConversationTarget, _ stream: UUID, account: String? = nil) -> WeChatConversationObservation {
            if target.stableID == helper.stableID {
                return observe([element("profile-name", target.title, 0.358, 0.146, 0.287),
                    element("profile-account", "Weixin ID: " + (account ?? "filehelper"), 0.388, 0.178, 0.347),
                    element("description-1", "Transfer text, images, audio and video files", 0.587, 0.273, 0.738),
                    element("description-2", "between your device and your PC", 0.508, 0.293, 0.581),
                    element("messages", "Messages", 0.502, 0.357, 0.247),
                    element("back-visual", "视觉:返回", 0.09, 0.08, 0.04, source: "local_visual"),
                    element("more-visual", "视觉:更多", 0.91, 0.08, 0.06, source: "local_visual")], stream)
            }
            return observe([element("profile-back", "通讯录", 0.1, 0.07), element("profile-name", target.title, 0.5, 0.18),
                element("profile-account", "微信号：wxid_intro_fixture", 0.55, 0.25, 0.65),
                element("moments", "朋友圈", 0.25, 0.48), element("messages", "发消息", 0.5, 0.7),
                element("call", "音视频通话", 0.5, 0.8)], stream)
        }
        func chat(_ target: ChatConversationTarget, _ rows: [PhoneUIElement], _ stream: UUID) -> WeChatConversationObservation {
            observe([element("back", "微信", 0.1, 0.08), element("title", target.title, 0.5, 0.08), element("input", "发送消息", 0.4, 0.9)] + rows, stream)
        }
        let intro = element("system-intro", phrase, 0.5, 0.22, 0.64)
        let secondIntro = element("system-intro-duplicate", phrase, 0.5, 0.28, 0.64)
        let real = element("real-message", note, 0.75, 0.48, 0.25)
        let outside = element("same-text-user-message", phrase, 0.75, 0.55, 0.25)
        let aliases = [phrase, "你可以在电脑与手机间互传文件", "你可以在手机和电脑间互传文件",
            "you can transfer files between your phone and computer.", "you can transfer files between your phone and computer"]
        for text in aliases {
            let page = chat(helper, [element("alias", text, 0.5, 0.22, 0.64)], UUID()).snapshot
            expect(PhonePageAdapters.selfTransferEvidenceCandidates(in: page).map(\.id) == ["alias"] && PhonePageAdapters.selfTransferEvidence(in: page)?.id == "alias", "Exact existing intro alias and unique wrapper agree")
        }
        for row in [outside, element("not-ocr", phrase, 0.5, 0.22, 0.64, source: "model"),
                    element("too-narrow", phrase, 0.5, 0.22, 0.44), element("not-exact", phrase + "。", 0.5, 0.22, 0.64)] {
            let snapshot = chat(helper, [row], UUID()).snapshot
            expect(PhonePageAdapters.selfTransferEvidenceCandidates(in: snapshot).isEmpty && PhonePageAdapters.selfTransferEvidence(in: snapshot) == nil, "Candidate extraction does not widen the original source/text/geometry predicate: " + row.id)
        }

        func summarize(_ session: ChatEvidenceSession, _ store: ChatEvidenceStore) async throws -> (Int, [String], ChatSummaryReport?) {
            var calls = 0, promptTexts: [String] = [], report: ChatSummaryReport?
            do {
                report = try await ChatEvidenceSummarizer { prompt in
                    calls += 1
                    let data = Data(prompt.components(separatedBy: "原消息数据：\n").last!.utf8)
                    let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                    let messages = payload["messages"] as! [[String: Any]]
                    promptTexts += messages.map { $0["text"] as! String }
                    let claims = messages.map { row -> [String: Any] in
                        ["category": "fact", "statement": row["text"]!, "citations": [["messageID": row["id"]!, "quote": row["text"]!]], "owner": NSNull(), "deadline": NSNull()]
                    }
                    return String(decoding: try JSONSerialization.data(withJSONObject: ["claims": claims]), as: UTF8.self)
                }.summarize(sessionID: session.id, store: store)
            } catch ChatEvidenceError.invalidSummary { }
            return (calls, promptTexts, report)
        }
        let cases: [(String, ChatConversationTarget, [PhoneUIElement], [String])] = [
            ("helper-profile-empty-intro", helper, [intro], []),
            ("helper-profile-one-real-intro", helper, [intro, real], [note]),
            ("helper-profile-empty-no-intro", helper, [], []),
            ("helper-profile-one-real-no-intro", helper, [real], [note]),
            ("helper-profile-outside-geometry", helper, [outside], [phrase]),
            ("helper-profile-intro-and-same-user-text", helper, [intro, outside], [phrase]),
            ("ordinary-qualified-same-text", ordinary, [intro], [phrase]),
            ("ordinary-duplicate-same-text", ordinary, [intro, secondIntro], [phrase, phrase]),
            ("ordinary-helper-nickname-same-text", ordinaryAlias, [intro], [phrase])
        ]
        for (name, target, rows, expected) in cases {
            let stream = UUID(), first = profile(target, stream), page = chat(target, rows, stream)
            let tape = ContactCaptureFixture([first, page]), url = folder.appendingPathComponent(name + ".json"), store = ChatEvidenceStore(url: url)
            let request = ChatReadRequest(scopeID: name, conversation: target, range: .currentPage(limit: 10), maxPages: 1)
            let session = try await tape.driver.read(request: request, store: store)
            let (calls, promptTexts, report) = try await summarize(session, store)
            let observed = session.messages.map { $0.observation.text }, stored = try store.session(id: name)
            actual.append(["case": name, "state": session.state.rawValue, "observed": observed, "selected": session.selectedMessages.map { $0.observation.text }, "modelCalls": calls, "modelTexts": promptTexts, "claims": report?.claims.count ?? 0, "reads": tape.reads, "taps": tape.taps, "scrolls": tape.scrolls.count, "rawSnapshotUnchanged": session.frames.first?.snapshot == page.snapshot])
            try preserve(url, name); try publish()
            expect(observed == expected && session.selectedMessages.map({ $0.observation.text }) == expected, name + ": only intended original rows are counted/selected")
            expect(session.state == .complete && session.frames.count == 1 && session.unmergedBatches == nil, name + ": current-page sample completes with a single accepted frame")
            expect(session.frames[0].snapshot == page.snapshot && session.frames[0].conversation.contactNavigation?.profile.snapshot == first.snapshot, name + ": original chat/profile snapshots and all intro elements remain intact")
            expect(session.frames[0].conversation.kind == .contactProfileNavigation && session.frames[0].conversation.contactNavigation?.profile.account == (target.stableID == helper.stableID ? "filehelper" : "wxid_intro_fixture"), name + ": exact independent account proof is retained")
            expect(tape.reads == 2 && tape.taps == ["messages"] && tape.scrolls.isEmpty, name + ": production navigation performs exactly one current-control tap and no scroll")
            expect(calls == (expected.isEmpty ? 0 : 1) && promptTexts == expected && (report?.claims.count ?? 0) == expected.count, name + ": no excluded intro reaches the echo model or valid report")
            expect(try ChatEvidenceStore(url: url).session(id: name) == stored, name + ": accepted rows, selection, proof and report reopen exactly")
            if target.stableID == helper.stableID {
                expect(session.messages.allSatisfy { !$0.observation.anchor.elementIDs.contains(intro.id) }, name + ": only the qualified system anchor is absent from message evidence")
            }
            if rows.contains(where: { $0.id == outside.id }) {
                expect(session.messages.contains { $0.observation.anchor.elementIDs == [outside.id] && $0.observation.text == phrase }, name + ": same text outside system geometry retains its original user anchor")
            }
        }
        for (name, account, rows, expectedError, expectedReads, expectedTaps) in [
            ("helper-profile-duplicate-intro", "filehelper", [intro, secondIntro, real], "ambiguousContinuity", 2, ["messages"]),
            ("helper-profile-wrong-account", "wxid_imposter123", [intro, real], "wrongConversation", 1, [])
        ] {
            let stream = UUID(), first = profile(helper, stream, account: account), page = chat(helper, rows, stream)
            let tape = ContactCaptureFixture([first, page]), url = folder.appendingPathComponent(name + ".json"), store = ChatEvidenceStore(url: url)
            let request = ChatReadRequest(scopeID: name, conversation: helper, range: .currentPage(limit: 10), maxPages: 1)
            var caught = "none"
            do { _ = try await tape.driver.read(request: request, store: store) }
            catch ChatEvidenceError.ambiguousContinuity { caught = "ambiguousContinuity" }
            catch ChatEvidenceError.wrongConversation { caught = "wrongConversation" }
            let stopped = try store.session(id: name), (calls, texts, report) = try await summarize(stopped, store)
            actual.append(["case": name, "error": caught, "state": stopped.state.rawValue, "acceptedFrames": stopped.frames.count, "acceptedMessages": stopped.messages.count, "modelCalls": calls, "reads": tape.reads, "taps": tape.taps, "scrolls": tape.scrolls.count])
            try preserve(url, name); try publish()
            expect(caught == expectedError && stopped.state == .stopped && stopped.frames.isEmpty && stopped.messages.isEmpty && stopped.pageSelection == nil, name + ": ambiguous system candidates or wrong account never enter accepted evidence")
            expect(calls == 0 && texts.isEmpty && report == nil && stopped.summaries.isEmpty && stopped.reports.isEmpty, name + ": no false message or report is produced")
            expect(tape.reads == expectedReads && tape.taps == expectedTaps && tape.scrolls.isEmpty, name + ": no retry or extra navigation follows rejection")
            expect(try ChatEvidenceStore(url: url).session(id: name) == stopped, name + ": stopped empty checkpoint reopens without invented raw identity proof")
        }
        let duplicatePage = chat(helper, [intro, secondIntro], UUID())
        expect(PhonePageAdapters.selfTransferEvidenceCandidates(in: duplicatePage.snapshot).map(\.id) == [intro.id, secondIntro.id] && PhonePageAdapters.selfTransferEvidence(in: duplicatePage.snapshot) == nil, "Duplicate extraction preserves both original candidates while the direct identity wrapper remains unique-only")
        var directDuplicateRejected = false
        do { _ = try ChatEvidenceFrame.from(snapshot: duplicatePage.snapshot) } catch ChatEvidenceError.wrongConversation { directDuplicateRejected = true }
        expect(directDuplicateRejected, "Direct builtin factory still rejects duplicate intro identity, unchanged")
        for rows in [[intro], [intro, real], [intro, outside]] {
            let page = chat(helper, rows, UUID()), name = "direct-control-\(rows.count)-\(rows.last!.id)"
            let frame = try ChatEvidenceFrame.from(snapshot: page.snapshot, id: page.frameID)
            let url = folder.appendingPathComponent(name + ".json"), store = ChatEvidenceStore(url: url)
            let request = ChatReadRequest(scopeID: name, conversation: helper, range: .currentPage(limit: 10), maxPages: 1)
            var reads = 0, scrolls = 0
            let session = try await ChatEvidenceReader(store: store).read(request: request, nextFrame: { reads += 1; return frame }, scroll: { _ in scrolls += 1 })
            let expected = rows.filter { $0.id != intro.id }.map(\.label), (calls, texts, report) = try await summarize(session, store)
            actual.append(["case": name, "observed": session.messages.map { $0.observation.text }, "modelCalls": calls, "modelTexts": texts, "claims": report?.claims.count ?? 0])
            try preserve(url, name); try publish()
            expect(frame.snapshot == page.snapshot && frame.conversation.kind == .builtInTransfer && frame.rows.map(\.text) == expected, "Direct builtin factory retains its original exact exclusion/provenance behavior")
            expect(session.selectedMessages.map({ $0.observation.text }) == expected && reads == 1 && scrolls == 0, "Direct controls still fix only the first independently identified page")
            expect(calls == (expected.isEmpty ? 0 : 1) && texts == expected && (report?.claims.count ?? 0) == expected.count, "Direct echo summary receives only remaining rows, including outside-geometry same text")
        }
        // An immutable real pre-fix production archive intentionally contains
        // the counted intro and its strict v2 report. Loading never reclassifies it.
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/legacy-profile-intro-pass5.json")
        let bytes = try Data(contentsOf: fixture), legacyURL = folder.appendingPathComponent("legacy-profile-intro.json")
        try bytes.write(to: legacyURL)
        let legacyStore = ChatEvidenceStore(url: legacyURL), legacy = legacyStore.sessions.first!
        let reportEncoder = JSONEncoder(); reportEncoder.outputFormatting = [.sortedKeys]
        let original = legacy, reportJSON = try reportEncoder.encode(legacy.reports)
        _ = legacy.reports.map { $0.markdown() }
        try legacyStore.save(legacy)
        expect(legacy.messages.map({ $0.observation.text }) == [phrase] && legacy.reports.last?.claims.count == 1, "Pre-fix counted intro/report fixture still loads with its original content")
        expect(try Data(contentsOf: legacyURL) == bytes && legacyStore.session(id: legacy.id) == original, "Load, render and save leave the complete pre-fix archive byte-for-byte unchanged")
        expect(try reportEncoder.encode(legacyStore.session(id: legacy.id).reports) == reportJSON, "Read-only JSON report export keeps all historical fields unchanged")
        var changedReports = legacy.reports; changedReports[0].claims[0].statement += " changed"
        expect(try reportEncoder.encode(changedReports) != reportJSON, "Stable JSON comparison still detects a real claim statement change")
        expect(try ChatEvidenceStore(url: legacyURL).session(id: legacy.id) == original, "Historical archive remains exactly readable after save, without factory migration")
        actual.append(["case": "legacy-profile-intro-pass5", "bytesUnchanged": try Data(contentsOf: legacyURL) == bytes, "retainedMessages": legacy.messages.count, "retainedReports": legacy.reports.count, "modelCalls": 0])
        try preserve(legacyURL, "legacy-profile-intro-pass5"); try publish()
        guard failures.isEmpty else { throw AgentError.message("System intro checks: " + failures.joined(separator: "; ")) }
        return checks
    }
}
