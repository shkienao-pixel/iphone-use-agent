import Foundation

// Only PhoneHarness's unrelated error dependency is a fixture. The entire XHS
// collector, source parser, deduplication, persistence and statistics are real.
enum AgentError: Error { case message(String) }

@MainActor
final class XHSReplay: XiaohongshuCollectionDriving {
    struct Note {
        var id: String?
        var title = "同一篇文案"
        var body = "人工智能 工具实测"
        var likes: String? = "12"
        var favorites: String? = "1万+"
        var comments: String? = nil
        var extraSource: String? = nil
    }
    var pages: [[Note]]
    var page = 0
    var note: Note?
    var shareID = "replay-share-1"
    var width = 1170
    var height = 2532
    var device = "replay-device"
    var keyword = "人工智能"
    var sort = "综合"
    var reads = 0, opens = 0, backs = 0, scrolls = 0
    var last: XiaohongshuCollectionFrame?
    var onRead: ((Int) -> Void)?
    var onOpen: (() -> Void)?
    var onBack: (() -> Void)?
    var wrongOpen = false
    var staleDate = false
    var overlay = false
    var transform: (([PhoneUIElement]) -> [PhoneUIElement])?
    init(_ pages: [[Note]]) { self.pages = pages }
    func element(_ id: String, _ text: String, _ x: Double, _ y: Double, _ w: Double = 0.3) -> PhoneUIElement {
        PhoneUIElement(id: id, label: text, rect: PhoneUIRect(x: x, y: y, width: w, height: 0.025), source: "ocr")
    }
    func read() async throws -> XiaohongshuCollectionFrame {
        reads += 1; onRead?(reads)
        var elements = [element("red", "小红书", 0.4, 0.02, 0.2)]
        if let note {
            elements += [element("follow", "关注", 0.8, 0.12, 0.15), element("composer", "说点什么", 0.12, 0.9),
                element("title", "标题：" + note.title, 0.1, 0.35, 0.8),
                element("body", "正文：" + note.body, 0.1, 0.5, 0.8),
                element("author", "作者：测试作者", 0.2, 0.21)]
            if let id = note.id { elements += [element("source", "https://www.xiaohongshu.com/explore/" + id + "?xsec_token=replay", 0.02, 0.77, 0.96)] }
            if let extra = note.extraSource { elements += [element("other-source", extra, 0.02, 0.73, 0.96)] }
            if let value = note.likes { elements += [element("likes", "点赞：" + value, 0.1, 0.83)] }
            if let value = note.favorites { elements += [element("favorites", "收藏：" + value, 0.4, 0.83)] }
            if let value = note.comments { elements += [element("comments", "评论：" + value, 0.7, 0.83, 0.25)] }
        } else {
            elements += [element("keyword", keyword, 0.2, 0.1), element("sort", "排序：" + sort + "（已选）", 0.1, 0.2, 0.15),
                element("users", "用户", 0.4, 0.2, 0.15), element("filter", "筛选", 0.8, 0.28, 0.15)]
            for index in pages[page].indices {
                elements += [element("card.\(index)", pages[page][index].title, index % 2 == 0 ? 0.04 : 0.54,
                    0.4 + Double(index / 2) * 0.16, 0.4)]
            }
        }
        let snapshot = PhoneUISnapshot(deviceKey: device, scene: "untrusted-scene-hint", elements: transform?(elements) ?? elements,
            capturedAt: staleDate ? Date().addingTimeInterval(-60) : Date(), blockingOverlay: overlay)
        let frame = XiaohongshuCollectionFrame(snapshot: snapshot, shareID: shareID, width: width, height: height)
        last = frame
        return frame
    }
    func openNote(_ element: PhoneUIElement) async throws {
        opens += 1
        guard let index = Int(element.id.split(separator: ".").last ?? ""), pages[page].indices.contains(index) else {
            throw XiaohongshuCollectionError.invalidObservation
        }
        if !wrongOpen { note = pages[page][index] }
        onOpen?()
    }
    func returnToResults() async throws { backs += 1; onBack?(); note = nil }
    func scrollResults(at element: PhoneUIElement) async throws {
        guard last?.snapshot.element(id: element.id) == element else { throw XiaohongshuCollectionError.invalidObservation }
        scrolls += 1; page = min(page + 1, pages.count - 1)
    }
}

@main struct XHSChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1; guard condition() else { fatalError(message) }
        }
        func rejects(_ body: () throws -> Void, _ message: String) {
            var threw = false; do { try body() } catch { threw = true }; expect(threw, message)
        }
        let reportParent = URL(fileURLWithPath: CommandLine.arguments[2]).deletingLastPathComponent()
        let replayRoot = reportParent.appendingPathComponent("replay-tmp", isDirectory: true)
        let folder = replayRoot.appendingPathComponent("xhs-replay-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var allChecksPassed = false
        defer {
            if allChecksPassed { try? FileManager.default.removeItem(at: folder) }
        }
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "folder": folder.path,
            "replayRoot": replayRoot.path, "reportParent": reportParent.path], options: .sortedKeys)
            .write(to: reportParent.appendingPathComponent("fixture-location.json"), options: .atomic)
        print("Xiaohongshu synthetic fixture folder: \(folder.path)")
        func store(_ suffix: String) -> XiaohongshuCollectionStore { .init(url: folder.appendingPathComponent(suffix + ".json")) }
        func task(_ id: String, _ samples: Int = 10) -> XiaohongshuCollectionTask {
            .init(id: id, keyword: "人工智能", sampleSize: samples)
        }
        let a = "0123456789abcdef01234567", b = "1123456789abcdef01234567", c = "2123456789abcdef01234567"
        let na = XHSReplay.Note(id: a), nb = XHSReplay.Note(id: b), nc = XHSReplay.Note(id: c)
        let countCases: [(String, XiaohongshuObservedCount.Kind, Int64?, Int64?)] = [
            ("0", .exact, 0, 0), ("1,234", .exact, 1234, 1234), ("1万+", .lowerBound, 10000, nil),
            ("1.2万", .interval, 11500, 12999), ("3k+", .lowerBound, 3000, nil),
            ("未知", .unknown, nil, nil), ("", .unknown, nil, nil), ("1.2", .unknown, nil, nil),
            ("-1", .unknown, nil, nil), ("999999999999999999999999", .unknown, nil, nil)]
        for (raw, kind, low, high) in countCases {
            let parsed = XiaohongshuObservedCount.parse(raw)
            expect(parsed.kind == kind && parsed.minimum == low && parsed.maximum == high, "Count parse preserves unknown/range: " + raw)
            try parsed.validate()
        }
        var badCount = XiaohongshuObservedCount.parse("12"); badCount.minimum = 13
        rejects({ try badCount.validate() }, "Count bounds must be recomputed from the raw display")

        let sourceFixture = XHSReplay([[na]])
        let goodElement = sourceFixture.element("url", "https://www.xiaohongshu.com/discovery/item/" + a, 0.1, 0.4)
        expect(XiaohongshuSource.extract(from: goodElement)?.noteID == a, "Actual source URL yields a stable platform ID")
        for url in ["https://xhslink.com/abcd", "小红书号：" + a, "https://evil.example/explore/" + a,
                    "https://www.xiaohongshu.com.evil.example/explore/" + a,
                    "https://www.xiaohongshu.com/explore/" + a + "a", "https://www.xiaohongshu.com/explore/" + a + "/other"] {
            expect(XiaohongshuSource.extract(from: sourceFixture.element("url", url, 0.1, 0.4)) == nil,
                "Short/author/fake/partial IDs never become note IDs: " + url)
        }
        var generated = goodElement; generated.source = "model"
        expect(XiaohongshuSource.extract(from: generated) == nil, "A model-supplied link is not independent evidence")

        // Same content/different IDs and scroll overlap all pass through the
        // production read -> open -> extract -> persist -> back -> scroll loop.
        let replay = XHSReplay([[na, nb], [nb, nc]])
        let originalStore = store("dedup")
        let collected = try await XiaohongshuCollector(store: originalStore).collect(task: task("dedup-0001", 3), driver: replay)
        expect(collected.status == .sampleReached, "Bounded local loop reaches verified unique sample count")
        expect(collected.notes.count == 3 && Set(collected.notes.map(\.id)) == [a, b, c], "Same-content notes with different actual IDs remain distinct")
        expect(collected.duplicateObservations == 1, "An overlapping ID is only counted once")
        expect(replay.scrolls == 1 && replay.opens == 4, "Loop uses local open/back/scroll without remote decisions")
        expect(collected.pages.count == 2 && collected.checkpoint?.noteOpenCount == 4, "Coverage and raw local operation counts are persisted")
        let stats = try collected.statistics()
        expect(stats.uniqueSamples == 3 && stats.sampleShortfall == 0, "Statistics recompute unique detail count")
        expect(stats.likes.exactTotal == 36 && stats.likes.exact == 3, "Exact sums are derived from details")
        expect(stats.favorites.lowerBounds == 3 && stats.favorites.observedMinimum == 30000 && stats.favorites.observedMaximum == nil && stats.favorites.exactTotal == nil,
            "1万+ stays unbounded and cannot produce an exact sum")
        expect(stats.comments.missing == 3 && stats.comments.observedMinimum == nil && stats.comments.exactTotal == nil,
            "Unknown comments remain missing rather than zero")
        expect(stats.likes.distribution["1-99"] == 3 && stats.favorites.distribution["10000+"] == 3 && stats.comments.missingFraction == 1,
            "Distribution and missing-value proportions are computed from unique raw details")
        expect(stats.keywordHitSamples == 3 && stats.keywordHitFraction == 1, "Keyword proportions use actual unique observed sample denominator")
        expect(stats.missingFields["comments"] == 3 && stats.unreadMediaNotes == 3, "Missing fields and unread image/video/comments are explicit")
        expect(collected.notes.allSatisfy { !$0.contentConclusionAllowed && $0.textCoverage == "visible_ocr_fragments_only" }, "Visible text is not declared a full note/media conclusion")
        expect(collected.notes.allSatisfy { $0.matchedKeywords == ["人工智能"] }, "Actual keyword hits are preserved")
        let exported = try originalStore.export(id: collected.id)
        let object = try JSONSerialization.jsonObject(with: exported) as! [String: Any]
        expect(object["recomputedStatistics"] != nil && object["analysisStatus"] != nil && object["run"] != nil, "Analysis is decoupled and exported with independent statistics")
        let disk = XiaohongshuCollectionStore(url: folder.appendingPathComponent("dedup.json"))
        let diskRun = try disk.run(id: collected.id)
        expect(diskRun == collected, "Atomic raw batches and checkpoint survive reopening")

        #if !canImport(UIKit)
        // Real production Store I/O on synthetic data: a successful host write
        // must remain readable without mutating protection or existing files.
        struct PlatformDocument: Encodable { let version = 1; let runs: [XiaohongshuCollectionRun] }
        let platformPath = folder.appendingPathComponent("platform/readback.json")
        let platformStore = XiaohongshuCollectionStore(url: platformPath)
        try platformStore.save(collected)
        let platformEncoder = JSONEncoder(); platformEncoder.outputFormatting = [.sortedKeys]
        let initialBytes = try Data(contentsOf: platformPath)
        let expectedInitialBytes = try platformEncoder.encode(PlatformDocument(runs: [collected]))
        expect(initialBytes == expectedInitialBytes, "Host production save is immediately readable as the exact encoded document bytes")
        let platformReopened = XiaohongshuCollectionStore(url: platformPath)
        expect(platformReopened.error == nil, "A fresh host Store reopens a successful production write without unavailable")
        let platformRun = try platformReopened.run(id: collected.id)
        expect(platformRun == collected, "Host disk reload preserves complete raw run and evidence")
        let initialExport = try platformStore.export(id: collected.id)
        let reopenedExport = try platformReopened.export(id: collected.id)
        expect(reopenedExport == initialExport, "Host save and reopened exports are byte-identical, including recomputed statistics")
        var platformReplacement = collected
        platformReplacement.stopReason = "synthetic_host_atomic_replacement"
        platformReplacement.updatedAt = Date()
        try platformStore.save(platformReplacement)
        let replacementBytes = try Data(contentsOf: platformPath)
        let expectedReplacementBytes = try platformEncoder.encode(PlatformDocument(runs: [platformReplacement]))
        expect(replacementBytes != initialBytes && replacementBytes == expectedReplacementBytes,
            "Host atomic replacement commits the exact new document and remains immediately readable")
        let replacementStore = XiaohongshuCollectionStore(url: platformPath)
        let replacementRun = try replacementStore.run(id: collected.id)
        let replacementExport = try replacementStore.export(id: collected.id)
        let writerExport = try platformStore.export(id: collected.id)
        let bytesAfterRead = try Data(contentsOf: platformPath)
        expect(replacementStore.error == nil && replacementRun == platformReplacement && replacementExport == writerExport && bytesAfterRead == replacementBytes,
            "A second host reopen and export preserve the replacement without modifying stored bytes")
        #endif

        var modelCalls = 0, promptSizes: [Int] = []
        let analysis = XiaohongshuAnalysisService(store: originalStore) { prompt in
            modelCalls += 1; promptSizes.append(prompt.count)
            let data = Data(prompt.components(separatedBy: "INPUT_EXCERPTS_JSON:\n").last!.utf8)
            let inputs = try JSONDecoder().decode([XiaohongshuAnalysisInput].self, from: data)
            let items = inputs.map { input in XiaohongshuFragmentTopic(noteID: input.noteID,
                quote: "人工智能 工具实测", topic: "工具实测") }
            struct Result: Encodable { let kind = "visible_fragment_topics"; var items: [XiaohongshuFragmentTopic] }
            return String(decoding: try JSONEncoder().encode(Result(items: items)), as: UTF8.self)
        }
        let analyzed = try await analysis.analyze(taskID: collected.id, batchSize: 2)
        expect(modelCalls == 2 && analyzed.analysisSegments.count == 2, "Production collection -> store -> bounded model batches -> persisted segments is connected")
        expect(promptSizes.allSatisfy { $0 <= 14000 }, "Every model prompt remains bounded to 14000 characters")
        expect(analyzed.analysisSegments.flatMap(\.items).allSatisfy { $0.quote.contains($0.topic) && [a, b, c].contains($0.noteID) }, "Topics have stable note IDs and exact visible quotations")
        _ = try await analysis.analyze(taskID: collected.id)
        expect(modelCalls == 2, "Repeated analysis sends no already-analyzed note/text hashes")
        let analyzedStats = try analyzed.statistics()
        expect(analyzedStats == stats, "Model analysis cannot alter program-derived numeric statistics")
        let analysisExport = String(decoding: try originalStore.export(id: collected.id), as: UTF8.self)
        expect(analysisExport.contains("visible_fragment_topics") && analysisExport.contains("unread_comments") && analysisExport.contains("missingFields"),
            "Export preserves partial text/media scope, exact citations and unknown fields")
        let parsedInputs = XiaohongshuAnalysisService.inputs(analyzed.notes[0])
        let invalidResponses = [
            "{\"kind\":\"full_summary\",\"items\":[]}",
            "{\"kind\":\"visible_fragment_topics\",\"items\":[],\"total\":999}",
            "{\"kind\":\"visible_fragment_topics\",\"items\":[{\"noteID\":\"wrong\",\"quote\":\"人工智能\",\"topic\":\"人工智能\"}]}",
            "{\"kind\":\"visible_fragment_topics\",\"items\":[{\"noteID\":\"" + a + "\",\"quote\":\"图片中有一只猫\",\"topic\":\"一只猫\"}]}",
            "{\"kind\":\"visible_fragment_topics\",\"items\":[{\"noteID\":\"" + a + "\",\"quote\":\"人工智能 工具实测\",\"topic\":\"全站用户喜欢AI\"}]}"
        ]
        for invalid in invalidResponses {
            rejects({ _ = try XiaohongshuAnalysisService.parse(invalid, inputs: parsedInputs, notes: analyzed.notes) },
                "Unsupported types, added totals, wrong IDs and invented image/generalization claims are rejected")
        }
        var changedRun = analyzed
        var changedNote = changedRun.notes[0]
        changedRun.noteRevisions.append(changedNote)
        changedNote.body = "人工智能 新增体验"
        changedNote.elements[changedNote.elements.firstIndex { $0.id == "body" }!].label = "正文：人工智能 新增体验"
        changedRun.notes[0] = changedNote; changedRun.updatedAt = Date()
        try originalStore.save(changedRun)
        let changedAnalysis = XiaohongshuAnalysisService(store: originalStore) { prompt in
            modelCalls += 1
            let data = Data(prompt.components(separatedBy: "INPUT_EXCERPTS_JSON:\n").last!.utf8)
            let inputs = try JSONDecoder().decode([XiaohongshuAnalysisInput].self, from: data)
            expect(inputs.count == 1 && inputs[0].noteID == a, "Only a changed stable-ID/text-hash is sent incrementally")
            return "{\"kind\":\"visible_fragment_topics\",\"items\":[{\"noteID\":\"" + a + "\",\"quote\":\"人工智能 新增体验\",\"topic\":\"新增体验\"}]}"
        }
        let changedAnalyzed = try await changedAnalysis.analyze(taskID: collected.id)
        expect(changedAnalyzed.analysisSegments.count == 3 && changedAnalyzed.noteRevisions.count == 1,
            "Changed observations retain old cited segments and persist only an incremental new batch")
        var longNote = changedNote
        longNote.body = String(repeating: "中文🙂\\\"\n", count: 2200)
        longNote.elements[longNote.elements.firstIndex { $0.id == "body" }!].label = "正文：" + longNote.body!
        let longInputs = XiaohongshuAnalysisService.inputs(longNote)
        expect(longInputs.count > 1 && longInputs.map(\.excerpt).joined() == longNote.analysisText, "Long visible text is partitioned without dropping or changing characters")
        let longPrompt = try XiaohongshuAnalysisService.prompt(Array(longInputs.prefix(1)))
        expect(longPrompt.count < 14000, "Even escaped Unicode chunks fit the prompt bound")
        let emptyStore = store("analysis-empty")
        var emptyRun = XiaohongshuCollectionRun(task: task("empty-text01", 1), startedAt: Date(), updatedAt: Date())
        var emptyNote = analyzed.notes[0]; emptyNote.title = nil; emptyNote.body = nil
        emptyRun.notes = [emptyNote]; try emptyStore.save(emptyRun)
        var emptyCalls = 0
        let emptyAnalyzed = try await XiaohongshuAnalysisService(store: emptyStore) { _ in emptyCalls += 1; return "{}" }.analyze(taskID: emptyRun.id)
        expect(emptyCalls == 0 && emptyAnalyzed.analysisSegments.isEmpty, "Missing visible text produces only program statistics without a fabricated model summary")

        let noID = XHSReplay([[.init(id: nil), .init(id: nil, title: "没有ID的第二笔")]])
        let pending = try await XiaohongshuCollector(store: store("pending")).collect(task: task("pending-0001", 2), driver: noID)
        expect(pending.notes.isEmpty && pending.pending.count == 6, "No-ID observations are retained as pending, never unique samples")
        expect(pending.status == .boundedStop && pending.stopReason.hasPrefix("repeated_viewport"), "Repeated viewport bounds scrolling even when sample target is unmet")
        expect(noID.scrolls == 2 && noID.opens == 6, "Repeated viewport is bounded after source verification, not title deduplication")
        let pendingStatistics = try pending.statistics()
        expect(pendingStatistics.sampleShortfall == 2, "Insufficient samples remain transparent")

        let ambiguous = XHSReplay([[.init(id: a, extraSource: "https://www.xiaohongshu.com/explore/" + b)]])
        let ambiguousResult = try await XiaohongshuCollector(store: store("ambiguous")).collect(task: task("ambiguous-01", 1), driver: ambiguous)
        expect(ambiguousResult.notes.isEmpty && ambiguousResult.pending.first?.reason.hasPrefix("ambiguous_platform") == true,
            "Multiple distinct source URLs do not identify the opened note")
        let unlabelled = XHSReplay([[na]])
        unlabelled.transform = { elements in elements.map { source in
            var value = source
            switch value.id {
            case "title": value.label = "公开可见标题"
            case "body": value.label = "人工智能工具的可见正文片段"
            case "author": value.label = "一个普通用户名"
            case "likes": value.label = "12"
            case "favorites": value.label = "1万+"
            default: break
            }
            return value
        } }
        let fragments = try await XiaohongshuCollector(store: store("fragments")).collect(task: task("fragments-01", 1), driver: unlabelled)
        expect(fragments.notes[0].body?.contains("人工智能工具的可见正文片段") == true,
            "Ordinary unlabelled page text is preserved as visible OCR fragments")
        expect(fragments.notes[0].title == nil && fragments.notes[0].author == nil && fragments.notes[0].likes.kind == .unknown,
            "Unlabelled title/user/toolbar numbers are not assigned guessed semantic roles")

        let changedScope = XHSReplay([[na]]); changedScope.keyword = "完全不同的词"
        let wrongScope = try await XiaohongshuCollector(store: store("scope")).collect(task: task("scope-000001", 1), driver: changedScope)
        expect(wrongScope.status == .paused && changedScope.opens == 0, "Wrong keyword stops before any candidate input")
        var filtered = task("filters-0001", 1); filtered.filters = ["本周"]
        let filterReplay = XHSReplay([[na]])
        let filterResult = try await XiaohongshuCollector(store: store("filters")).collect(task: filtered, driver: filterReplay)
        expect(filterResult.status == .paused && filterReplay.opens == 0, "Invisible requested filters cannot be claimed applied")
        let wrongOpen = XHSReplay([[na]]); wrongOpen.wrongOpen = true
        let wrongOpenResult = try await XiaohongshuCollector(store: store("wrong-open")).collect(task: task("wrong-open-01", 1), driver: wrongOpen)
        expect(wrongOpenResult.status == .paused && wrongOpenResult.notes.isEmpty && wrongOpen.opens == 1,
            "An input dispatch without a note postcondition never counts as collection")

        let interrupted = XHSReplay([[na, nb]])
        let resumeStore = store("resume")
        var running: Task<XiaohongshuCollectionRun, Error>?
        interrupted.onBack = { running?.cancel() }
        running = Task { try await XiaohongshuCollector(store: resumeStore).collect(task: task("resume-00001", 2), driver: interrupted) }
        do { _ = try await running!.value; fatalError("Expected cancellation") } catch is CancellationError { }
        let cancelled = try resumeStore.run(id: "resume-00001")!
        expect(cancelled.status == .cancelled && cancelled.notes.count == 1, "Cancellation preserves the already persisted batch")
        interrupted.onBack = nil
        let resumed = try await XiaohongshuCollector(store: resumeStore).collect(task: task("resume-00001", 2), driver: interrupted)
        expect(resumed.status == .sampleReached && resumed.notes.count == 2, "Resume continues local collection from checkpoint without double counting")
        expect(interrupted.opens == 2, "Resume does not replay a visited result candidate")

        let noteResumeReplay = XHSReplay([[na, nb]])
        let noteResumeStore = store("note-resume")
        var noteTask: Task<XiaohongshuCollectionRun, Error>?
        noteResumeReplay.onOpen = { noteTask?.cancel() }
        noteTask = Task { try await XiaohongshuCollector(store: noteResumeStore).collect(task: task("note-resume1", 2), driver: noteResumeReplay) }
        do { _ = try await noteTask!.value; fatalError("Expected cancellation after opening note") } catch is CancellationError { }
        noteResumeReplay.onOpen = nil
        let notePaused = try await XiaohongshuCollector(store: noteResumeStore).collect(task: task("note-resume1", 2), driver: noteResumeReplay)
        expect(notePaused.status == .paused && notePaused.notes.isEmpty && notePaused.stopReason.hasPrefix("current_note_requires_fresh_collection_scope") && noteResumeReplay.opens == 1 && noteResumeReplay.backs == 0,
            "An interrupted note cannot inherit current scope from the old viewport and receives no automatic Back or further input")
        noteResumeReplay.note = nil // User explicitly returns to the configured results page.
        let noteResumed = try await XiaohongshuCollector(store: noteResumeStore).collect(task: task("note-resume1", 2), driver: noteResumeReplay)
        expect(noteResumed.notes.count == 2 && Set(noteResumed.notes.map(\.id)).count == 2, "After the user restores results, fresh scope collection completes without double counting source IDs")

        for change in ["share", "size", "device", "overlay", "stale"] {
            let invalid = XHSReplay([[na]])
            invalid.onRead = { number in
                guard number == 2 else { return }
                switch change {
                case "share": invalid.shareID = "different-share"
                case "size": invalid.height += 1
                case "device": invalid.device = "different-device"
                case "overlay": invalid.overlay = true
                default: invalid.staleDate = true
                }
            }
            let invalidStore = store(change)
            var rejected = false
            do { _ = try await XiaohongshuCollector(store: invalidStore).collect(task: task("invalid-" + change, 1), driver: invalid) } catch { rejected = true }
            expect(rejected, "Changed sharing/device/size, overlays and stale frames fail closed: " + change)
            let invalidRun = try invalidStore.run(id: "invalid-" + change)
            expect(invalidRun?.notes.isEmpty == true, "Invalid observation never creates a sample: " + change)
        }

        // Rebinding after interruption is allowed only from freshly verified
        // matching results; known IDs remain deduplicated across a new stream.
        let rebind = XHSReplay([[na, nb]])
        let rebindStore = store("rebind")
        var rebindTask: Task<XiaohongshuCollectionRun, Error>?
        rebind.onBack = { rebindTask?.cancel() }
        rebindTask = Task { try await XiaohongshuCollector(store: rebindStore).collect(task: task("rebind-00001", 2), driver: rebind) }
        do { _ = try await rebindTask!.value } catch is CancellationError { }
        rebind.onBack = nil; rebind.shareID = "new-share"; rebind.width = 1200
        let rebound = try await XiaohongshuCollector(store: rebindStore).collect(task: task("rebind-00001", 2), driver: rebind)
        expect(rebound.notes.count == 2 && rebound.events.contains { $0.kind == "resume_rebind" }, "Verified new sharing geometry rebinds without losing dedup details")

        let badPath = folder.appendingPathComponent("corrupt.json"), badBytes = Data("{incomplete".utf8)
        try badBytes.write(to: badPath)
        let broken = XiaohongshuCollectionStore(url: badPath)
        rejects({ _ = try broken.run(id: "corrupt-0001") }, "Malformed storage cannot become an empty resumable run")
        rejects({ try broken.save(collected) }, "Malformed storage is never overwritten")
        let retainedBadBytes = try Data(contentsOf: badPath)
        expect(retainedBadBytes == badBytes, "Original corrupt bytes remain available for recovery")
        var tampered = collected; tampered.notes.append(tampered.notes[0])
        rejects({ _ = try tampered.statistics() }, "Statistics reject duplicate IDs instead of trusting a stale count")
        tampered = collected; tampered.notes[0].source.noteID = b
        rejects({ try tampered.validate() }, "A stable ID must still match preserved source evidence")
        tampered = collected; tampered.notes[0].likes = .parse("999")
        rejects({ try tampered.validate() }, "A stored metric must match the actual OCR field, not only a valid-looking number")
        tampered = collected; tampered.notes[0].body = "不存在于屏幕的结论"
        rejects({ try tampered.validate() }, "Stored analysis text must originate from preserved OCR evidence")
        var conflict = collected; conflict.task.keyword = "other"
        rejects({ try originalStore.save(conflict) }, "A task ID cannot silently change collection scope")
        var badTask = task("short"); badTask.sampleSize = 0
        rejects({ try badTask.validate() }, "Invalid limits and identity are rejected")
        var pagesTask = task("page-limit01", 10); pagesTask.stops.maxPages = 1
        let pageLimit = try await XiaohongshuCollector(store: store("page-limit")).collect(task: pagesTask, driver: XHSReplay([[na], [nb]]))
        expect(pageLimit.notes.count == 1 && pageLimit.stopReason == "max_pages", "Page bound is enforced without reducing requested sample in the report")
        var attemptsTask = task("attempts-001", 1); attemptsTask.stops.maxNotes = 1
        let attemptsLimit = try await XiaohongshuCollector(store: store("attempt-limit")).collect(task: attemptsTask, driver: XHSReplay([[.init(id: nil), nb]]))
        expect(attemptsLimit.notes.isEmpty && attemptsLimit.pending.count == 1 && attemptsLimit.stopReason == "max_note_attempts", "Pending records also consume bounded note attempts")
        // Encode the actual production cancellation receipt, then remove only
        // fields introduced in Build 74 to reproduce a legitimate Build 73 file.
        var legacyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cancelled)) as! [String: Any]
        legacyObject.removeValue(forKey: "sourceAttempts")
        var legacyTask = legacyObject["task"] as! [String: Any]; legacyTask.removeValue(forKey: "profileID"); legacyObject["task"] = legacyTask
        var legacyNotes = legacyObject["notes"] as! [[String: Any]]
        for index in legacyNotes.indices {
            legacyNotes[index].removeValue(forKey: "pageAdapterVersion")
            legacyNotes[index]["pageEvidence"] = ["red", "follow", "composer"]
        }
        legacyObject["notes"] = legacyNotes
        var legacyPages = legacyObject["pages"] as! [[String: Any]]
        for index in legacyPages.indices {
            for key in ["selectionEvidence", "screenshotSHA256", "scopeVersion", "scopeCapture"] { legacyPages[index].removeValue(forKey: key) }
            var elements = legacyPages[index]["elements"] as! [[String: Any]]
            for item in elements.indices where elements[item]["id"] as? String == "sort" { elements[item]["label"] = "综合" }
            legacyPages[index]["elements"] = elements
        }
        legacyObject["pages"] = legacyPages
        if var checkpoint = legacyObject["checkpoint"] as? [String: Any] { checkpoint.removeValue(forKey: "scopeCapture"); legacyObject["checkpoint"] = checkpoint }
        let legacyPath = folder.appendingPathComponent("build73-archive.json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "runs": [legacyObject]]).write(to: legacyPath)
        let legacyStore = XiaohongshuCollectionStore(url: legacyPath)
        let legacyRun = try legacyStore.run(id: cancelled.id)!
        expect(legacyStore.error == nil && legacyRun.notes.count == 1 && legacyRun.sourceAttempts.isEmpty,
            "A legitimate Build 73 archive loads with empty new source transactions rather than being treated as corrupt")
        expect(legacyRun.task.profileID == nil && legacyRun.task.range == "currentSearchResults" && legacyRun.pages[0].scopeVersion == 1,
            "Old task ranges and original pages retain their original meaning without a new profile or retroactive selected proof")
        let legacyStats = try legacyRun.statistics()
        expect(legacyStats.conditionEvidence.contains("legacy") && legacyStats.uniqueSamples == 1,
            "Old selected-state gaps remain transparent while source-backed old samples remain usable")
        let legacyReplay = XHSReplay([[na, nb]])
        let legacyResumed = try await XiaohongshuCollector(store: legacyStore).collect(task: legacyRun.task, driver: legacyReplay)
        expect(legacyResumed.status == .sampleReached && legacyResumed.notes.count == 2 && legacyReplay.opens == 1,
            "A decoded old checkpoint resumes through the actual production collector without re-counting or reopening the old note")
        checks += try await XHSAdapterChecks.run(folder: folder)
        checks += try await XHSNativeLatestChecks.run(folder: folder)
        checks += try await XHSScopeRenewalChecks.run(folder: folder)
        checks += try await XHSSourceCompletionChecks.run(folder: folder)
        checks += try await XHSLongReadingChecks.run(folder: folder)
        checks += try await XHSAnalysisWrapperChecks.run(folder: folder, fixture: URL(fileURLWithPath: CommandLine.arguments[1]), report: URL(fileURLWithPath: CommandLine.arguments[2]))
        checks += try await XHSDerivedValidationChecks.run(folder: folder, fixture: URL(fileURLWithPath: CommandLine.arguments[1]), report: URL(fileURLWithPath: CommandLine.arguments[2]).deletingLastPathComponent().appendingPathComponent("derived-validation-report.json"))
        print("Xiaohongshu production collection checks passed: \(checks)")
        allChecksPassed = true
    }
}
