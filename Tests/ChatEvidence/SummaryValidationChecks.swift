import Foundation

/// Synthetic production I/O only. No phone, capture permission or model API.
@MainActor enum ChatSummaryValidationChecks {
    static func run(folder: URL) async throws -> Int {
        var checks = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func rejects(_ message: String, _ body: () throws -> Void) {
            var failed = false; do { try body() } catch { failed = true }; expect(failed, message)
        }
        let target = ChatConversationTarget(stableID: "wechat.builtin.file-transfer", title: "文件传输助手", deviceKey: "summary-validation-fixture")
        let texts = [
            "验收数据01：项目名为“公开样例A”。", "验收数据02：本批只检查样例A的页面文案。",
            "验收数据03：小林明确负责整理样例A的文案。", "验收数据04：小林承诺在2026年10月28日18:00前交付文案。",
            "验收数据05：决定采用版本B作为本次测试方案。", "验收数据06：测试步骤为阅读、核对、归档。",
            "验收数据07：更正第04条，交付期限改为2026年10月29日18:00。", "验收数据08：版本B只用于本次功能验收。",
            "验收数据09：这十条均为人工构造的非敏感测试文字。", "验收数据10：本批测试输入到此结束。"
        ]
        func frame(_ values: [String]) throws -> ChatEvidenceFrame {
            let date = Date(timeIntervalSince1970: 1_700_010_000), id = UUID().uuidString
            func e(_ id: String, _ label: String, _ x: Double, _ y: Double, _ width: Double = 0.18) -> PhoneUIElement {
                .init(id: id, label: label, rect: .init(x: x - width / 2, y: y - 0.015, width: width, height: 0.03), source: "ocr")
            }
            let rows = values.enumerated().map { e("row-\($0.offset)", $0.element, 0.75, 0.32 + Double($0.offset) * 0.045) }
            let snapshot = PhoneUISnapshot(deviceKey: target.deviceKey, scene: "wechat.chat", elements: [
                e("back", "微信", 0.1, 0.08), e("title", target.title, 0.5, 0.08),
                e("proof", "可以在手机和电脑间互传文件", 0.5, 0.22, 0.64), e("input", "发送消息", 0.4, 0.9)
            ] + rows, capturedAt: date)
            var value = try ChatEvidenceFrame.from(snapshot: snapshot, id: id, reachedBoundary: true)
            // Trusted synthetic metadata for summary validation, not OCR dates.
            for index in value.rows.indices { value.rows[index].sentAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index)) }
            return value
        }
        func make(_ id: String, values: [String]? = nil) async throws -> ChatEvidenceStore {
            let store = ChatEvidenceStore(url: folder.appendingPathComponent(id + ".json")), value = try frame(values ?? texts)
            let request = ChatReadRequest(scopeID: id, conversation: target, range: .time(start: Date(timeIntervalSince1970: 1_700_000_000), end: Date(timeIntervalSince1970: 1_700_001_000)), maxPages: 1)
            _ = try await ChatEvidenceReader(store: store).read(request: request, nextFrame: { value }, scroll: { _ in })
            return store
        }
        func json(_ claims: [ChatSummaryClaim]) throws -> String {
            struct Envelope: Encodable { var claims: [ChatSummaryClaim] }
            var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Envelope(claims: claims))) as! [String: Any]
            var values = value["claims"] as! [[String: Any]]
            for i in values.indices {
                if values[i]["owner"] == nil { values[i]["owner"] = NSNull() }
                if values[i]["deadline"] == nil { values[i]["deadline"] = NSNull() }
            }
            value["claims"] = values
            return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        func citation(_ message: ChatEvidenceMessage) -> ChatEvidenceCitation { .init(messageID: message.id, quote: message.observation.text) }
        func rejectModel(_ id: String, store: ChatEvidenceStore, output: String, _ message: String) async throws {
            let before = try store.session(id: id)
            var rejected = false
            do { _ = try await ChatEvidenceSummarizer(model: { _ in output }).summarize(sessionID: id, store: store) }
            catch ChatEvidenceError.invalidSummary { rejected = true }
            expect(rejected, message)
            expect(try store.session(id: id) == before, message + " leaves the complete checkpoint unchanged")
        }
        let store = try await make("summary-v2"), messages = try store.session(id: "summary-v2").messages
        let oldDate = "2026年10月28日18:00", newDate = "2026年10月29日18:00"
        let fact = ChatSummaryClaim(category: .fact, statement: "项目名为公开样例A", citations: [citation(messages[0])])
        let corrected = ChatSummaryClaim(category: .correction, statement: "期限由28日更正为29日", citations: [citation(messages[3]), citation(messages[6])], deadline: newDate)
        var incorrect = corrected; incorrect.deadline = oldDate
        try await rejectModel("summary-v2", store: store, output: json([incorrect]), "Correction cannot take its active deadline from the superseded source")
        incorrect = corrected; incorrect.owner = "小林"
        try await rejectModel("summary-v2", store: store, output: json([incorrect]), "An owner absent from the latest correction excerpt must stay null")
        var reversed = corrected; reversed.citations.reverse()
        try await rejectModel("summary-v2", store: store, output: json([reversed]), "Current correction citations still reject reverse source order")
        var inference = corrected; inference.category = .inference
        try await rejectModel("summary-v2", store: store, output: json([inference]), "Inference remains unable to carry an active deadline")
        var invented = fact; invented.citations[0].messageID = "not-a-message"
        try await rejectModel("summary-v2", store: store, output: json([invented]), "Current validation continues rejecting invented message IDs")
        invented = fact; invented.citations[0].quote = "并不存在的原文"
        try await rejectModel("summary-v2", store: store, output: json([invented]), "Current validation continues rejecting invented excerpts")
        try await rejectModel("summary-v2", store: store, output: json(Array(repeating: fact, count: 201)), "Raw claims over 200 reject before exact deduplication")
        try await rejectModel("summary-v2", store: store, output: String(repeating: " ", count: 500_001), "Raw model output over 500k rejects before decoding or deduplication")
        let report = try await ChatEvidenceSummarizer(model: { _ in try json([fact, fact, corrected, corrected]) }).summarize(sessionID: "summary-v2", store: store)
        expect(report.claims == [fact, corrected], "Exact full claim tuples are stably deduplicated before saving")
        expect(report.validationVersion == 2 && report.id.hasPrefix("cr-v2-"), "New report carries both the current version and producer marker")
        let current = try store.session(id: "summary-v2")
        expect(current.summaries.count == 1 && current.summaries[0].claims == [fact, corrected] && current.summaries[0].validationVersion == 2 && current.summaries[0].id.hasPrefix("cs-v2-"), "New segment stores unique claims with paired current producer/version")
        expect(report.markdown().contains("；期限：" + newDate) && !report.markdown().contains("；期限：" + oldDate), "Corrected 29th deadline renders while earlier evidence remains quoted")
        expect(report.claims[1].citations.map(\.messageID) == [messages[3].id, messages[6].id], "Deduplication does not erase the prior commitment or reorder correction citations")
        rejects("Direct v2 validation rejects persisted duplicate tuples", { try ChatEvidenceSummarizer.validate(claims: [fact, fact], messages: messages) })
        var changedStatement = fact; changedStatement.statement += "（原文）"
        var changedCategory = fact; changedCategory.category = .decision
        var changedQuote = fact; changedQuote.citations[0].quote = "公开样例A"
        let task = ChatSummaryClaim(category: .task, statement: "原交付承诺", citations: [citation(messages[3])])
        var taskOwner = task; taskOwner.owner = "小林"
        var taskDeadline = task; taskDeadline.deadline = oldDate
        expect(ChatSummaryValidation.deduplicated([fact, fact, changedStatement, changedCategory, changedQuote, task, taskOwner, taskDeadline]).count == 7,
            "Category, statement, quote, owner and deadline each participate in exact tuple identity")
        var oppositeOrder = corrected; oppositeOrder.citations.reverse()
        expect(ChatSummaryValidation.deduplicated([corrected, oppositeOrder]).count == 2, "Ordered citation arrays are part of tuple identity even though reversed provenance later rejects")
        var twins = texts; twins[9] = twins[8]
        let twinStore = try await make("summary-twins", values: twins), twinMessages = try twinStore.session(id: "summary-twins").messages
        let twinClaims = twinMessages.suffix(2).map { ChatSummaryClaim(category: .fact, statement: "相同文字独立出现", citations: [citation($0)]) }
        let twinReport = try await ChatEvidenceSummarizer(model: { _ in try json(twinClaims) }).summarize(sessionID: "summary-twins", store: twinStore)
        expect(twinReport.claims.count == 2 && twinClaims[0].citations[0].messageID != twinClaims[1].citations[0].messageID, "Same visible text from distinct actual message occurrences is never deduplicated")
        let budgetStore = try await make("summary-budget"), budgetMessages = try budgetStore.session(id: "summary-budget").messages
        let budgetClaim = ChatSummaryClaim(category: .fact, statement: "预算内", citations: [citation(budgetMessages[0])])
        let budgetReport = try await ChatEvidenceSummarizer(model: { _ in try json(Array(repeating: budgetClaim, count: 200)) }).summarize(sessionID: "summary-budget", store: budgetStore)
        expect(budgetReport.claims.count == 1, "A bounded 200-item duplicate response is accepted as one exact claim")

        struct Document: Codable { var version = 1; var sessions: [ChatEvidenceSession] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var legacy = current
        var legacyCorrection = corrected; legacyCorrection.owner = "小林"; legacyCorrection.deadline = oldDate
        let legacySegment = ChatSummarySegment(id: "cs-" + UUID().uuidString.lowercased(), messageIDs: messages.map(\.id), claims: [legacyCorrection, legacyCorrection], generatedAt: Date())
        let legacyReport = ChatSummaryReport(id: "cr-" + UUID().uuidString.lowercased(), scopeID: legacy.id, conversation: target, range: legacy.request.range,
            messageIDs: messages.map(\.id), segmentIDs: [legacySegment.id], claims: [legacyCorrection, legacyCorrection], warnings: ["synthetic legacy archive"], generatedAt: Date())
        legacy.summaries = [legacySegment]; legacy.reports = [legacyReport]
        let legacyPath = folder.appendingPathComponent("summary-legacy.json"), rawLegacy = try encoder.encode(Document(sessions: [legacy]))
        try rawLegacy.write(to: legacyPath, options: .atomic)
        expect(!String(decoding: rawLegacy, as: UTF8.self).contains("validationVersion"), "Full historical document really omits all newly optional version fields")
        let oldStore = ChatEvidenceStore(url: legacyPath)
        let loadedLegacy = try oldStore.session(id: legacy.id)
        expect(oldStore.error.isEmpty && loadedLegacy == legacy, "A complete v1 archive with old duplicate/old correction slots stays readable under original provenance rules")
        let exportedLegacy = try encoder.encode(loadedLegacy)
        expect(try JSONDecoder().decode(ChatEvidenceSession.self, from: exportedLegacy) == legacy, "Full legacy session export preserves original unsafe slots and duplicates without rewriting raw history")
        let oldMarkdown = legacyReport.markdown()
        expect(oldMarkdown.contains("旧版历史报告") && oldMarkdown.contains("不展示") && oldMarkdown.contains("重新总结") && oldMarkdown.contains("重新处理当前选中的原消息范围"), "Legacy rendering explicitly warns about validation, suppressed unsupported slots and full selected-range regeneration")
        expect(!oldMarkdown.contains("；负责人：小林") && !oldMarkdown.contains("；期限：" + oldDate) && oldMarkdown.contains(texts[3]) && oldMarkdown.contains(texts[6]), "Legacy rendering suppresses unsupported active fields while retaining both verbatim historical sources")
        expect(legacyReport.claims[0].deadline == oldDate && legacyReport.claims.count == 2, "Rendering does not mutate the retained legacy raw report")
        var unvalidatedCurrent = report; unvalidatedCurrent.claims = [legacyCorrection]
        expect(unvalidatedCurrent.markdown().contains("已停止展示这些活动负责人/期限") && !unvalidatedCurrent.markdown().contains("；期限：" + oldDate),
            "Standalone current rendering explicitly warns if unsupported correction slots were supplied without Store validation")
        try oldStore.save(loadedLegacy)
        expect(try Data(contentsOf: legacyPath) == rawLegacy, "Saving an unchanged known legacy document preserves its exact encoded bytes")
        let legacyReopened = ChatEvidenceStore(url: legacyPath)
        expect(try legacyReopened.session(id: legacy.id) == legacy, "Known legacy full document remains readable after save and reopen")
        var regenerationCalls = 0, regenerationInputCount = 0
        let regenerating = ChatEvidenceSummarizer(model: { prompt in
            regenerationCalls += 1
            let payload = prompt.components(separatedBy: "原消息数据：\n").last!
            let input = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as! [String: Any]
            regenerationInputCount = (input["newMessageIDs"] as! [String]).count
            return try json([corrected, corrected])
        })
        expect(regenerationCalls == 0, "Loading, rendering, exporting and reopening legacy history never call a model")
        let regenerated = try await regenerating.summarize(sessionID: legacy.id, store: legacyReopened)
        let afterRegeneration = try legacyReopened.session(id: legacy.id)
        expect(regenerationCalls == 1 && regenerationInputCount == 10, "Explicit legacy format upgrade processes the selected original range once instead of falsely claiming incremental-only work")
        expect(regenerated.validationVersion == 2 && regenerated.claims == [corrected] && !regenerated.segmentIDs.contains(legacySegment.id), "Unsafe legacy segment is not reused as current proof; new v2 report uses fresh strict evidence")
        expect(afterRegeneration.summaries.first == legacySegment && afterRegeneration.reports.first == legacyReport && afterRegeneration.summaries.count == 2, "Regeneration appends current proof without altering historical raw segment or report")
        let upgradedStore = ChatEvidenceStore(url: legacyPath)
        expect(try upgradedStore.session(id: legacy.id) == afterRegeneration, "Mixed legacy and current full document reopens without losing either history")
        _ = try await regenerating.summarize(sessionID: legacy.id, store: upgradedStore)
        expect(regenerationCalls == 1, "Once current v2 segments exist, later explicit summaries reuse them without retransmitting the old range")

        let originalBytes = try Data(contentsOf: folder.appendingPathComponent("summary-v2.json"))
        var invalid = current
        invalid.summaries[0].validationVersion = nil
        rejects("Deleting a new segment version cannot downgrade its retained cs-v2 marker", { try store.save(invalid) })
        invalid = current; invalid.reports[0].validationVersion = nil
        rejects("Deleting a new report version cannot downgrade its retained cr-v2 marker", { try store.save(invalid) })
        invalid = current; invalid.summaries[0].validationVersion = 1
        rejects("An explicit unsupported segment version fails closed", { try store.save(invalid) })
        invalid = current; invalid.reports[0].validationVersion = 99
        rejects("An unknown report validation version fails closed", { try store.save(invalid) })
        invalid = current; invalid.summaries[0].id = "cs-" + UUID().uuidString.lowercased(); invalid.reports = []
        rejects("Current segment version cannot adopt a legacy producer ID", { try store.save(invalid) })
        invalid = current; invalid.reports[0].id = "cr-" + UUID().uuidString.lowercased()
        rejects("Current report version cannot adopt a legacy producer ID", { try store.save(invalid) })
        invalid = current; invalid.summaries[0].id = "cr-v2-" + UUID().uuidString.lowercased(); invalid.summaries[0].validationVersion = nil; invalid.reports = []
        rejects("A known report v2 marker cannot be downgraded to a legacy segment by omitting its version", { try store.save(invalid) })
        invalid = current; invalid.reports[0].id = "cs-v2-" + UUID().uuidString.lowercased(); invalid.reports[0].validationVersion = nil
        rejects("A known segment v2 marker cannot be downgraded to a legacy report by omitting its version", { try store.save(invalid) })
        invalid = current; invalid.summaries[0].id = "cr-v2-" + UUID().uuidString.lowercased(); invalid.reports = []
        rejects("A segment with version2 also rejects the opposite known producer kind", { try store.save(invalid) })
        invalid = current; invalid.reports[0].id = "cs-v2-" + UUID().uuidString.lowercased()
        rejects("A report with version2 also rejects the opposite known producer kind", { try store.save(invalid) })
        invalid = current; invalid.summaries = [legacySegment]; invalid.reports[0].segmentIDs = [legacySegment.id]
        rejects("A current report cannot cite legacy-only segments as current validation proof", { try store.save(invalid) })
        expect(try Data(contentsOf: folder.appendingPathComponent("summary-v2.json")) == originalBytes, "Rejected current/downgraded documents never replace the committed valid bytes")
        invalid = current; invalid.reports[0].validationVersion = nil
        let downgradePath = folder.appendingPathComponent("summary-downgraded.json"), downgradeBytes = try encoder.encode(Document(sessions: [invalid]))
        try downgradeBytes.write(to: downgradePath, options: .atomic)
        let downgradedStore = ChatEvidenceStore(url: downgradePath)
        rejects("Loading retained new producer proof with deleted version fails closed", { _ = try downgradedStore.session(id: current.id) })
        expect(try Data(contentsOf: downgradePath) == downgradeBytes, "A rejected downgraded archive is preserved byte-for-byte")
        var unknown = current; unknown.summaries[0].validationVersion = 99
        let unknownPath = folder.appendingPathComponent("summary-unknown.json")
        try encoder.encode(Document(sessions: [unknown])).write(to: unknownPath, options: .atomic)
        let unknownStore = ChatEvidenceStore(url: unknownPath)
        rejects("Loading an unknown segment version fails closed", { _ = try unknownStore.session(id: current.id) })
        expect(unknown.reports[0].markdown().contains("关键事实"), "A valid current report still renders its ordinary categories")
        var unsupportedReport = report; unsupportedReport.validationVersion = 99
        expect(unsupportedReport.markdown().contains("未展示结论") && !unsupportedReport.markdown().contains("；期限："), "Unsupported standalone report rendering also fails closed")
        return checks
    }
}
