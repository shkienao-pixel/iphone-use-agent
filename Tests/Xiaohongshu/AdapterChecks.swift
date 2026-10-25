import Foundation

@MainActor final class XHSNativeReplay: XiaohongshuCollectionDriving {
    enum Mode { case results, note, share, filters }
    enum Selection { case explicit, pixels, visibleOnly }
    var mode = Mode.results
    var selection = Selection.explicit
    var english = false
    var profile = false
    var profileID = "author-7788"
    var ids = ["3123456789abcdef01234567", "4123456789abcdef01234567"]
    var selectedIndex = 0
    var shareTaps = 0, copyTaps = 0, closeTaps = 0, noteOpens = 0, returns = 0, resolutions = 0
    var filterOpens = 0, filterCloses = 0
    var counter = 20
    var copiedText: String?
    var clipboardTextOverride: String?
    var foreground = true, effectiveCopy = true, autoClose = true, wrongShare = false, duplicateCopy = false
    var wrongRestore = false, wrongBack = false, evilRedirect = false, wrongHash = false, blockingPanel = false
    var directLink = false, oldPixels = false
    var visualShare = false
    var onCopy: (() -> Void)?
    var onShare: (() -> Void)?
    var last: XiaohongshuCollectionFrame?
    let shareID = "native-fixture-share"
    func e(_ id: String, _ text: String, _ x: Double, _ y: Double, _ w: Double = 0.25) -> PhoneUIElement {
        .init(id: id, label: text, rect: .init(x: x, y: y, width: w, height: 0.025), source: "ocr")
    }
    func read() async throws -> XiaohongshuCollectionFrame {
        var elements: [PhoneUIElement]
        switch mode {
        case .results:
            if profile {
                elements = [e("profile-id", "小红书号：" + profileID, 0.1, 0.2, 0.7),
                    e("sort", selection == .explicit ? "笔记（已选）" : "笔记", 0.1, 0.5), e("saved", "收藏", 0.45, 0.5)]
                elements += ids.indices.map { e("card.\($0)", "用户笔记 \($0)", $0 == 0 ? 0.02 : 0.53, 0.65, 0.43) }
            } else {
                let sort = english ? "Best" : "综合"
                elements = [e("search", english ? "Search" : "搜索", 0.01, 0.08, 0.15),
                    e("query", wrongBack ? "错误关键词" : "人工智能", 0.25, 0.08, 0.5),
                    e("sort", sort + (selection == .explicit ? (english ? " (Selected)" : "（已选）") : ""), 0.03, 0.2),
                    e("users", english ? "Users" : "用户", 0.36, 0.2, 0.17),
                    e("shopping", english ? "Shopping" : "商品", 0.58, 0.2, 0.18),
                    e("filter", english ? "Filters" : "筛选", 0.80, 0.28, 0.18)]
                elements += ids.indices.map { e("card.\($0)", "人工智能笔记 \($0)", $0 == 0 ? 0.02 : 0.53, 0.45, 0.43) }
            }
        case .note:
            elements = [e("follow", english ? "Follow" : "关注", 0.8, 0.12, 0.15),
                e("composer", english ? "Add a comment" : "说点什么", 0.1, 0.91, 0.6),
                e("body", wrongRestore && copyTaps > 0 ? "已经换成别的笔记" : "人工智能工具的同文可见正文", 0.1, 0.43, 0.8),
                e("like", english ? "Like" : "点赞", 0.05, 0.82, 0.2),
                e("save", english ? "Save" : "收藏", 0.35, 0.82, 0.2),
                e("share", english ? "More" : "更多", 0.85, 0.03, 0.12),
                e("back", english ? "Back" : "返回", 0.02, 0.03, 0.15)]
            if visualShare, let index = elements.firstIndex(where: { $0.id == "share" }) {
                elements[index].source = "local_visual"; elements[index].label = "视觉:更多"
            }
        case .share:
            elements = [e("heading", wrongShare ? "系统菜单" : (english ? "Share to" : "分享至"), 0.1, 0.52, 0.7),
                e("copy", english ? "Copy link" : "复制链接", 0.15, 0.69, 0.3),
                e("cancel", english ? "Cancel" : "取消", 0.35, 0.9, 0.3)]
            if duplicateCopy { elements += [e("copy-duplicate", english ? "Copy link" : "复制链接", 0.55, 0.69, 0.3)] }
        case .filters:
            elements = [e("sort-heading", english ? "Sort by" : "排序依据", 0.05, 0.28, 0.8),
                e("sort", (english ? "Best" : "综合") + (selection == .explicit ? (english ? " (Selected)" : "（已选）") : ""), 0.08, 0.38, 0.25),
                e("latest", english ? "Latest" : "最新", 0.45, 0.38, 0.25),
                e("type-heading", english ? "Note type" : "笔记类型", 0.05, 0.49, 0.8),
                e("all-types", english ? "All notes (Selected)" : "全部笔记（已选）", 0.05, 0.58, 0.5),
                e("reset", english ? "Reset" : "重置", 0.1, 0.83, 0.25),
                e("done", english ? "Done" : "完成", 0.65, 0.83, 0.25)]
        }
        let date = oldPixels ? Date().addingTimeInterval(-100) : Date()
        let snapshot = PhoneUISnapshot(deviceKey: "native-source-device", scene: "untrusted", elements: elements,
            capturedAt: date, blockingOverlay: blockingPanel && mode == .share)
        let hash = String(repeating: "a", count: 64)
        let selected = selection == .pixels ? XiaohongshuPageAdapter.localSelectionEvidence(snapshot: snapshot, screenshotSHA256: hash) { x, y in
            guard let sort = elements.first(where: { $0.id == "sort" }) else { return nil }
            if x >= sort.rect.x && x <= sort.rect.x + sort.rect.width && y >= sort.rect.y && y <= sort.rect.y + sort.rect.height + 0.02 {
                return .init(red: 0.95, green: 0.12, blue: 0.22)
            }
            return .init(red: 0.9, green: 0.9, blue: 0.9)
        } : []
        let frame = XiaohongshuCollectionFrame(snapshot: snapshot, shareID: shareID, width: 1170, height: 2532,
            selectionEvidence: selected, screenshotSHA256: wrongHash ? String(repeating: "b", count: 64) : hash, confirmedAt: Date())
        last = frame; return frame
    }
    func openNote(_ element: PhoneUIElement) async throws {
        guard mode == .results, last?.snapshot.element(id: element.id) == element,
              let index = Int(element.id.split(separator: ".").last ?? ""), ids.indices.contains(index) else {
            throw XiaohongshuCollectionError.invalidObservation
        }
        selectedIndex = index; mode = .note; noteOpens += 1
    }
    func tapObserved(_ element: PhoneUIElement) async throws {
        guard last?.snapshot.element(id: element.id) == element else { throw XiaohongshuCollectionError.invalidObservation }
        switch element.id {
        case "filter": filterOpens += 1; mode = .filters
        case "done": filterCloses += 1; mode = .results
        case "share": shareTaps += 1; mode = .share; onShare?()
        case "copy":
            copyTaps += 1
            if effectiveCopy {
                counter += 1
                let url = directLink ? "https://www.xiaohongshu.com/discovery/item/" + ids[selectedIndex] : "http://xhslink.com/a/fixture-\(selectedIndex)"
                copiedText = clipboardTextOverride ?? "分享笔记，复制后打开 REDnote：" + url
            }
            if autoClose { mode = .note }
            onCopy?()
        case "cancel": closeTaps += 1; mode = .note
        default: throw XiaohongshuCollectionError.invalidObservation
        }
    }
    func clipboardSnapshot(readText: Bool) async throws -> XiaohongshuClipboardSnapshot {
        if readText && !foreground { throw XiaohongshuClipboardError.foregroundRequired }
        return .init(changeCount: counter, text: readText ? copiedText : nil, readAt: Date())
    }
    func resolveShortLink(_ url: URL) async throws -> XiaohongshuResolvedLink {
        resolutions += 1
        guard let index = Int(url.lastPathComponent.split(separator: "-").last ?? ""), ids.indices.contains(index) else {
            throw XiaohongshuClipboardError.invalidLink
        }
        let final = "https://www.xiaohongshu.com/explore/" + ids[index] + "?xsec_source=" + (profile ? "pc_user" : "pc_search")
        return .init(redirectChain: evilRedirect ? [url.absoluteString, "https://evil.example/bounce", final] : [url.absoluteString, final], finalURL: final)
    }
    func returnToResults() async throws { returns += 1; mode = .results }
    func scrollResults(at element: PhoneUIElement) async throws { }
}

@MainActor enum XHSAdapterChecks {
    static func run(folder: URL) async throws -> Int {
        var count = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); count += 1 }
        func rejects(_ message: String, _ body: () async throws -> Void) async {
            var rejected = false; do { try await body() } catch { rejected = true }; expect(rejected, message)
        }
        func task(_ name: String, samples: Int = 1) -> XiaohongshuCollectionTask { .init(id: "native-" + name, keyword: "人工智能", sampleSize: samples) }
        func store(_ name: String) -> XiaohongshuCollectionStore { .init(url: folder.appendingPathComponent("native-" + name + ".json")) }
        for english in [false, true] {
            let fixture = XHSNativeReplay(); fixture.english = english
            let frame = try await fixture.read()
            expect(XiaohongshuPageAdapter.identity(in: frame.snapshot)?.scene == "xiaohongshu.results", "Common result tabs identify the page without a top brand: \(english)")
            expect(XiaohongshuCollector.scopeEvidence(task: task("locale-\(english)"), frame: frame) == nil,
                "A selected General content category does not prove the separate actual sort selection")
            let localeStore = store("locale-\(english)")
            let collection = try await XiaohongshuCollector(store: localeStore).collect(task: task("locale-\(english)", samples: 2), driver: fixture)
            expect(collection.notes.count == 2 && collection.status == .sampleReached, "Common no-URL notes use the real share/copy/clipboard/resolver production path")
            expect(fixture.copyTaps == 2 && fixture.shareTaps == 2 && fixture.resolutions == 2 && fixture.returns == 1,
                "Share and Copy occur once per actual note; results restore before the next candidate")
            expect(collection.notes.allSatisfy { $0.source.shareCapture != nil && $0.source.clipboard != nil && $0.source.resolvedLink != nil },
                "Notes preserve original OCR/screenshot/clipboard/redirect evidence without synthesizing an OCR URL")
            expect(collection.notes[0].body == collection.notes[1].body && collection.notes[0].id != collection.notes[1].id,
                "Same-content notes remain separate after obtaining their actual different platform IDs")
            expect(collection.sourceAttempts.allSatisfy { $0.stage == .completed }, "Each controlled Copy transaction has a durable completed receipt")
            expect(fixture.filterOpens == 1 && fixture.filterCloses == 1 && collection.pages[0].scopeCapture != nil,
                "The current filter menu is inspected once and the same query is restored before collection")
            if let path = ProcessInfo.processInfo.environment["XHS_REPLAY_OUTPUT_DIR"] {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try localeStore.export(id: collection.id).write(to: directory.appendingPathComponent(english ? "xhs-synthetic-source-chain-en.json" : "xhs-synthetic-source-chain-zh.json"))
            }
        }
        let visible = XHSNativeReplay(); visible.selection = .visibleOnly
        let visibleResult = try await XiaohongshuCollector(store: store("visible")).collect(task: task("visible"), driver: visible)
        expect(visibleResult.status == .paused && visible.noteOpens == 0, "Merely visible sort text cannot prove its selected state")
        let pixels = XHSNativeReplay(); pixels.selection = .pixels
        let pixelsResult = try await XiaohongshuCollector(store: store("pixels")).collect(task: task("pixels"), driver: pixels)
        expect(pixelsResult.status == .sampleReached && pixelsResult.pages[0].selectionEvidence.contains { $0.method == .redTextAndUnderline },
            "Actual current-image red foreground plus underline supports selected-state evidence")
        let forged = XHSNativeReplay(); forged.selection = .pixels; forged.wrongHash = true
        let forgedResult = try await XiaohongshuCollector(store: store("forged")).collect(task: task("forged"), driver: forged)
        expect(forgedResult.status == .paused && forged.noteOpens == 0, "Selection pixels from another screenshot cannot establish scope")
        let markerFixture = XHSNativeReplay(); markerFixture.selection = .visibleOnly
        let markerFrame = try await markerFixture.read()
        let onlyRedText = XiaohongshuPageAdapter.localSelectionEvidence(snapshot: markerFrame.snapshot, screenshotSHA256: String(repeating: "a", count: 64)) { _, y in
            y < 0.225 ? .init(red: 1, green: 0, blue: 0) : .init(red: 0.5, green: 0.5, blue: 0.5)
        }
        expect(XiaohongshuPageAdapter.selected("综合", snapshot: markerFrame.snapshot, evidence: onlyRedText,
            screenshotSHA256: String(repeating: "a", count: 64)) == nil, "Decorative red text without the underline does not imply selected state")
        let sort = markerFrame.snapshot.elements.first { $0.id == "sort" }!
        let pinkChip = XiaohongshuPageAdapter.localSelectionEvidence(snapshot: markerFrame.snapshot, screenshotSHA256: String(repeating: "a", count: 64)) { x, y in
            guard x >= sort.rect.x && x <= sort.rect.x + sort.rect.width else { return nil }
            if y >= sort.rect.y && y <= sort.rect.y + sort.rect.height { return .init(red: 1, green: 0.1, blue: 0.2) }
            if abs(y - sort.rect.y) < 0.005 || abs(y - sort.rect.y - sort.rect.height) < 0.005 { return .init(red: 1, green: 0.85, blue: 0.9) }
            return .init(red: 1, green: 1, blue: 1)
        }
        expect(pinkChip.contains { $0.elementID == "sort" && $0.method == .redTextAndFilledChip },
            "Selected pink chips require both the actual red text and surrounding tinted background")
        let latestTask = XiaohongshuCollectionTask(id: "native-latest", keyword: "人工智能", sampleSize: 1, sort: "最新")
        let mismatch = XHSNativeReplay()
        let mismatchResult = try await XiaohongshuCollector(store: store("latest")).collect(task: latestTask, driver: mismatch)
        expect(mismatchResult.status == .paused && mismatch.noteOpens == 0, "An actually selected General sort cannot satisfy a requested Latest sort")
        let filtered = XHSNativeReplay()
        var filterTask = task("selected-filter"); filterTask.filters = ["全部笔记"]
        let filteredResult = try await XiaohongshuCollector(store: store("selected-filter")).collect(task: filterTask, driver: filtered)
        expect(filteredResult.notes.count == 1 && filteredResult.pages[0].scopeCapture?.filterPanel.snapshot.elements.contains { $0.id == "all-types" } == true,
            "Requested filters bind to actual selected controls in their own filter group, not mere option text")
        let wrongFilter = XHSNativeReplay(); filterTask.id = "native-wrong-filter"; filterTask.filters = ["本周"]
        let wrongFilterResult = try await XiaohongshuCollector(store: store("wrong-filter")).collect(task: filterTask, driver: wrongFilter)
        expect(wrongFilterResult.status == .paused && wrongFilter.copyTaps == 0 && wrongFilter.filterCloses == 1,
            "A mismatched selected filter closes the inspected panel without changing choices or collecting")

        let panel = XHSNativeReplay(); panel.autoClose = false
        let panelResult = try await XiaohongshuCollector(store: store("panel")).collect(task: task("panel"), driver: panel)
        expect(panelResult.status == .sampleReached && panel.closeTaps == 1 && panel.copyTaps == 1,
            "Copy that leaves the share panel open is followed by its observed Cancel and a verified same note")
        let foreground = XHSNativeReplay(); foreground.foreground = false
        let foregroundStore = store("foreground"), foregroundCollector = XiaohongshuCollector(store: foregroundStore)
        let waiting = try await foregroundCollector.collect(task: task("foreground"), driver: foreground)
        expect(waiting.status == .paused && waiting.notes.isEmpty && waiting.pending.count == 1 && waiting.pending[0].sourceCapture != nil,
            "A background clipboard restriction persists the exact Copy evidence and awaits a foreground read")
        let callsBefore = foreground.copyTaps
        _ = try await foregroundCollector.collect(task: task("foreground"), driver: foreground)
        expect(foreground.copyTaps == callsBefore, "Restart does not repeat an already dispatched Copy while source text is pending")
        foreground.foreground = true
        let actualClipboard = try await foreground.clipboardSnapshot(readText: true)
        var changed = actualClipboard; changed.changeCount += 1
        await rejects("A later clipboard replacement cannot be attached to the previous note") {
            _ = try await foregroundCollector.completeCopiedSource(taskID: waiting.id, clipboard: changed, resolveShortLink: foreground.resolveShortLink)
        }
        var expired = actualClipboard; expired.readAt = waiting.pending[0].sourceCapture!.copiedAt.addingTimeInterval(121)
        await rejects("A clipboard read after the bounded source lease cannot complete an old Copy") {
            _ = try await foregroundCollector.completeCopiedSource(taskID: waiting.id, clipboard: expired, resolveShortLink: foreground.resolveShortLink)
        }
        let completed = try await foregroundCollector.completeCopiedSource(taskID: waiting.id, clipboard: actualClipboard, resolveShortLink: foreground.resolveShortLink)
        expect(completed.status == .sampleReached && completed.notes.count == 1 && foreground.copyTaps == 1,
            "The actual foreground read completes only the same immutable Copy change without another UI input")
        let foregroundReload = XiaohongshuCollectionStore(url: folder.appendingPathComponent("native-foreground.json"))
        expect(try foregroundReload.run(id: completed.id)?.notes.first?.source.clipboard == actualClipboard,
            "The actual clipboard receipt and bound source survive reopening")

        for failure in ["copy-no-change", "wrong-panel", "duplicate-copy", "wrong-restored-note", "evil-redirect", "wrong-domain", "overlay"] {
            let fixture = XHSNativeReplay()
            switch failure {
            case "copy-no-change": fixture.effectiveCopy = false
            case "wrong-panel": fixture.wrongShare = true
            case "duplicate-copy": fixture.duplicateCopy = true
            case "wrong-restored-note": fixture.wrongRestore = true
            case "evil-redirect": fixture.evilRedirect = true
            case "wrong-domain": fixture.clipboardTextOverride = "https://www.xiaohongshu.com.evil.example/explore/" + fixture.ids[0]
            default: fixture.blockingPanel = true
            }
            let storage = store(failure), collector = XiaohongshuCollector(store: storage)
            await rejects("Source acquisition fails closed for " + failure) { _ = try await collector.collect(task: task(failure), driver: fixture) }
            let failed = try storage.run(id: task(failure).id)!
            expect(failed.notes.isEmpty && !failed.pending.isEmpty && fixture.copyTaps <= 1,
                "Uncertain source is preserved but never counted or retried: " + failure)
            let copies = fixture.copyTaps
            let paused = try await collector.collect(task: task(failure), driver: fixture)
            expect(paused.status == .paused && fixture.copyTaps == copies, "Durable uncertain source dispatch prevents retry on resume: " + failure)
        }
        for atCopy in [false, true] {
            let fixture = XHSNativeReplay(), storage = store("cancel-\(atCopy)")
            let collector = XiaohongshuCollector(store: storage)
            var running: Task<XiaohongshuCollectionRun, Error>?
            if atCopy { fixture.onCopy = { running?.cancel() } } else { fixture.onShare = { running?.cancel() } }
            running = Task { try await collector.collect(task: task("cancel-\(atCopy)"), driver: fixture) }
            do { _ = try await running!.value; preconditionFailure("Cancellation ignored") } catch is CancellationError { count += 1 }
            let cancelled = try storage.run(id: task("cancel-\(atCopy)").id)!
            expect(cancelled.status == .cancelled && cancelled.notes.isEmpty && cancelled.sourceAttempts.last?.stage == .uncertain,
                "Cancellation preserves an uncertain source transaction before any resume")
            let copies = fixture.copyTaps
            _ = try await collector.collect(task: task("cancel-\(atCopy)"), driver: fixture)
            expect(fixture.copyTaps == copies && copies == (atCopy ? 1 : 0), "Cancellation never repeats a possibly completed Copy")
        }
        let direct = XHSNativeReplay(); direct.directLink = true
        let directResult = try await XiaohongshuCollector(store: store("direct")).collect(task: task("direct"), driver: direct)
        expect(directResult.notes.count == 1 && direct.resolutions == 0 && directResult.notes[0].source.shareCapture != nil,
            "A full platform link copied by the controlled UI needs no short-link network resolution")
        let visual = XHSNativeReplay(); visual.visualShare = true
        let visualResult = try await XiaohongshuCollector(store: store("visual-share")).collect(task: task("visual-share"), driver: visual)
        expect(visualResult.notes.count == 1 && visualResult.notes[0].source.shareCapture?.note.snapshot.element(id: "share")?.source == "local_visual",
            "A native current-pixel ellipsis observation with screenshot proof supports an icon-only share control")
        let oldPixels = XHSNativeReplay(); oldPixels.oldPixels = true
        let idleResult = try await XiaohongshuCollector(store: store("idle")).collect(task: task("idle"), driver: oldPixels)
        expect(idleResult.notes.count == 1 && idleResult.notes[0].observedAt < idleResult.startedAt,
            "Confirmed current idle pixels remain usable while preserving their actual older capture timestamp")

        let profile = XHSNativeReplay(); profile.profile = true
        var profileTask = task("profile"); profileTask.range = "currentProfileNotes"; profileTask.profileID = profile.profileID; profileTask.sort = "主页顺序"
        let profileResult = try await XiaohongshuCollector(store: store("profile")).collect(task: profileTask, driver: profile)
        expect(profileResult.notes.count == 1 && profileResult.pages[0].scopeEvidence.contains("profile-id"),
            "A selected Notes tab and exact platform profile identity bind profile collection and its copied note ID")
        let wrongProfile = XHSNativeReplay(); wrongProfile.profile = true
        profileTask.id = "native-wrong-profile"; profileTask.profileID = "different-id"
        let wrongProfileResult = try await XiaohongshuCollector(store: store("wrong-profile")).collect(task: profileTask, driver: wrongProfile)
        expect(wrongProfileResult.status == .paused && wrongProfile.noteOpens == 0, "A display profile with another actual ID cannot satisfy the requested profile scope")
        for text in ["https://evil.example/a", "https://www.xiaohongshu.com.evil.example/a", "https://user:pw@www.xiaohongshu.com/explore/" + direct.ids[0],
                     "https://www.xiaohongshu.com:443/explore/" + direct.ids[0], "https://xhslink.com/a/one https://xhslink.com/a/two"] {
            expect(XiaohongshuSource.copiedURL(in: text) == nil, "Clipboard source parsing rejects wrong/credentialed/ambiguous URL: " + text)
        }
        let generic = PhoneUISnapshot(deviceKey: "fixture", scene: "unknown", elements: [profile.e("copy", "复制链接", 0.2, 0.5)], capturedAt: Date())
        expect(XiaohongshuPageAdapter.identity(in: generic) == nil, "Copy link alone never proves a trusted XHS share panel")
        for english in [false, true] {
            let fixture = XHSNativeReplay(); fixture.english = english; fixture.mode = .note
            let frame = try await fixture.read()
            var comments = frame.snapshot
            comments.elements.append(fixture.e("count", english ? "12 comments" : "共12条评论", 0.1, 0.6, 0.7))
            expect(XiaohongshuPageAdapter.identity(in: comments)?.scene == "xiaohongshu.comments", "Common comment panels are identified but not treated as read note text")
            let search = PhoneUISnapshot(deviceKey: "locale", scene: "unknown", elements: [
                fixture.e("search", english ? "Search" : "搜索", 0.1, 0.08), fixture.e("cancel", english ? "Cancel" : "取消", 0.8, 0.08, 0.15),
                fixture.e("history", english ? "Recent searches" : "搜索历史", 0.05, 0.3, 0.8),
                fixture.e("trending", english ? "Trending searches" : "猜你想搜", 0.05, 0.5, 0.8)], capturedAt: Date())
            expect(XiaohongshuPageAdapter.identity(in: search)?.scene == "xiaohongshu.search", "Common search-history screens support Chinese and English without a fabricated brand anchor")
        }
        return count
    }
}
