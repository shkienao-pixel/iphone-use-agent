import Foundation

/// Verify persisted proof and failed-save isolation across local lookup indexes.
@MainActor enum ChatStoreIndexChecks {
    static func run(folder: URL, fixture: ChatEvidenceSession) throws -> Int {
        var checks = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        var baseline = fixture
        baseline.request.scopeID = "store-index-safety"
        // Stored legacy provenance remains valid; this test never uploads it.
        baseline.request.range = .latest(count: baseline.messages.count)
        baseline.summaries = []; baseline.reports = []
        let messages = baseline.messages
        precondition(messages.count >= 5)
        let claim = ChatSummaryClaim(category: .fact, statement: "合成有序来源",
            citations: [.init(messageID: messages[0].id, quote: messages[0].observation.text),
                        .init(messageID: messages[3].id, quote: messages[3].observation.text)])
        let segment = ChatSummarySegment(id: "cs-v2-" + UUID().uuidString.lowercased(),
            messageIDs: [messages[3].id, messages[4].id], contextMessageIDs: [messages[1].id, messages[0].id],
            claims: [claim], generatedAt: Date(), validationVersion: 2)
        baseline.summaries = [segment]
        baseline.reports = [.init(id: "cr-v2-" + UUID().uuidString.lowercased(), scopeID: baseline.id,
            conversation: baseline.request.conversation, range: baseline.request.range,
            messageIDs: messages.map(\.id), segmentIDs: [segment.id], claims: [claim],
            warnings: ["仅人工合成索引回归"], generatedAt: Date(), validationVersion: 2)]
        let url = folder.appendingPathComponent("store-index-safety.json"), store = ChatEvidenceStore(url: folder.appendingPathComponent("store-index-safety.json"))
        try store.save(baseline)
        let bytes = try Data(contentsOf: url)
        expect(try ChatEvidenceStore(url: url).session(id: baseline.id) == baseline,
            "Unordered context IDs reconstruct original evidence order and reopen exactly")

        func rejects(_ name: String, _ mutate: (inout ChatEvidenceSession) -> Void) throws {
            var invalid = baseline; mutate(&invalid)
            var rejected = false
            do { try store.save(invalid) } catch { rejected = true }
            expect(rejected, name)
            let unchanged = try store.session(id: baseline.id) == baseline && Data(contentsOf: url) == bytes
            expect(unchanged, "Rejected index proof must not change memory or original disk bytes")
        }
        try rejects("Duplicate frame ID rejects before unique-key index construction") { $0.frames.append($0.frames[0]) }
        try rejects("Duplicate message ID rejects before unique-key index construction") { $0.messages[1].id = $0.messages[0].id }
        try rejects("Duplicate segment ID rejects before unique-key index construction") { $0.summaries.append($0.summaries[0]) }
        try rejects("Duplicate report ID remains rejected") { $0.reports.append($0.reports[0]) }
        try rejects("An unknown frame cannot satisfy an anchor lookup") { value in
            value.messages[0].anchors[0].frameID = "missing-frame"
            value.messages[0].observation.anchor = value.messages[0].anchors[0]
        }
        try rejects("Same frame ID still requires the full stored anchor rectangle") { value in
            value.messages[0].anchors[0].rect.x += 0.01
            value.messages[0].observation.anchor = value.messages[0].anchors[0]
        }
        try rejects("Matching IDs cannot replace full message occurrence validation") { $0.messages[0].observation.text += " changed" }
        try rejects("Missing segment evidence IDs still fail the exact count check") { $0.summaries[0].contextMessageIDs.append("missing-message") }
        try rejects("Duplicate IDs across batch and context remain rejected") { $0.summaries[0].contextMessageIDs.append($0.summaries[0].messageIDs[0]) }
        try rejects("Reversed segment message order remains rejected") { $0.summaries[0].messageIDs.reverse() }
        try rejects("A missing report segment cannot be supplied by an unrelated ID") { $0.reports[0].segmentIDs = ["missing-segment"] }
        try rejects("A missing report message remains rejected") { $0.reports[0].messageIDs.append("missing-message") }
        try rejects("Report order follows its declared message IDs, not dictionary iteration") { $0.reports[0].messageIDs.reverse() }
        try rejects("Reference existence cannot excuse reversed citation order") { $0.reports[0].claims[0].citations.reverse() }
        try store.save(baseline)
        expect(try Data(contentsOf: url) == bytes, "Valid repeated save keeps the exact sorted-key disk format")
        return checks
    }
}
