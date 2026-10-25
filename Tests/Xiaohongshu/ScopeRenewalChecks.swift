import Foundation

@MainActor final class XHSScopeRenewalReplay: XiaohongshuCollectionDriving {
    enum CurrentSort { case original, latest, twoSelected, duplicateOriginal, visibleLatest }
    let fixture = XHSNativeReplay()
    var currentSort = CurrentSort.original
    var onReturn: (() -> Void)?
    func read() async throws -> XiaohongshuCollectionFrame {
        var frame = try await fixture.read()
        if fixture.mode == .results {
            let index = frame.snapshot.elements.firstIndex { $0.id == "sort" }!
            switch currentSort {
            case .original: break
            case .latest: frame.snapshot.elements[index].label = "排序：最新（已选）"
            case .twoSelected, .duplicateOriginal:
                frame.snapshot.elements[index].label = "排序：综合（已选）"
                frame.snapshot.elements.append(fixture.e("second-selected-sort", currentSort == .twoSelected ? "排序：最新（已选）" : "排序：综合（已选）", 0.35, 0.2, 0.3))
            case .visibleLatest: frame.snapshot.elements.append(fixture.e("visible-latest", "排序：最新", 0.35, 0.2, 0.3))
            }
        } else if fixture.mode == .filters, currentSort == .latest {
            let original = frame.snapshot.elements.firstIndex { $0.id == "sort" }!, latest = frame.snapshot.elements.firstIndex { $0.id == "latest" }!
            frame.snapshot.elements[original].label = "综合"
            frame.snapshot.elements[latest].label = "最新（已选）"
        }
        return frame
    }
    func openNote(_ element: PhoneUIElement) async throws { try await fixture.openNote(element) }
    func returnToResults() async throws { try await fixture.returnToResults(); onReturn?() }
    func scrollResults(at element: PhoneUIElement) async throws { try await fixture.scrollResults(at: element) }
    func tapObserved(_ element: PhoneUIElement) async throws { try await fixture.tapObserved(element) }
    func clipboardSnapshot(readText: Bool) async throws -> XiaohongshuClipboardSnapshot { try await fixture.clipboardSnapshot(readText: readText) }
    func resolveShortLink(_ url: URL) async throws -> XiaohongshuResolvedLink { try await fixture.resolveShortLink(url) }
}

@MainActor enum XHSScopeRenewalChecks {
    static func run(folder: URL) async throws -> Int {
        var checks = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func task(_ suffix: String) -> XiaohongshuCollectionTask { .init(id: "renew-scope-" + suffix, keyword: "人工智能", sampleSize: 2) }
        let url = folder.appendingPathComponent("scope-renewal.json"), store = XiaohongshuCollectionStore(url: url), driver = XHSScopeRenewalReplay()
        let request = task("disk")
        var running: Task<XiaohongshuCollectionRun, Error>?
        driver.onReturn = { running?.cancel() }
        running = Task { try await XiaohongshuCollector(store: store).collect(task: request, driver: driver) }
        var cancelled = false
        do { _ = try await running!.value } catch is CancellationError { cancelled = true }
        let old = try store.run(id: request.id)!, oldCapture = old.checkpoint!.scopeCapture!
        let oldCaptureBytes = try encoder.encode(oldCapture), oldPagesBytes = try encoder.encode(old.pages)
        expect(cancelled && old.status == .cancelled && old.notes.count == 1, "Production filter/share/source loop really cancels after one complete persisted note")
        let reopened = XiaohongshuCollectionStore(url: url)
        expect(try reopened.run(id: request.id) == old, "Scope recovery uses an actual reopened checkpoint rather than a helper-only capture")
        driver.onReturn = nil; driver.currentSort = .latest
        let wrong = try await XiaohongshuCollector(store: reopened).collect(task: request, driver: driver)
        expect(wrong.status == .paused && wrong.notes.count == 1 && wrong.stopReason.hasPrefix("current_sort_conflicts_or_is_ambiguous"), "A fresh explicit Latest selection cannot be covered by the old General capture")
        expect(driver.fixture.noteOpens == 1 && driver.fixture.shareTaps == 1 && driver.fixture.copyTaps == 1 && driver.fixture.filterOpens == 1,
            "A conflicting current sort pauses before a new note, Share, Copy, filter mutation or extra navigation")
        let wrongCaptureBytes = try encoder.encode(wrong.checkpoint!.scopeCapture!), wrongPagesBytes = try encoder.encode(wrong.pages)
        expect(wrongCaptureBytes == oldCaptureBytes && wrongPagesBytes == oldPagesBytes, "Rejected renewal retains historical proof and pages byte-for-byte without promoting or rewriting them")
        let afterWrong = XiaohongshuCollectionStore(url: url)
        expect(try afterWrong.run(id: request.id) == wrong, "The safe paused receipt and original history survive a second actual disk reopen")
        driver.currentSort = .original
        let resumed = try await XiaohongshuCollector(store: afterWrong).collect(task: request, driver: driver)
        expect(resumed.status == .sampleReached && resumed.notes.count == 2 && Set(resumed.notes.map(\.id)).count == 2, "Unchanged restored scope completes the same two unique IDs without counting the old note twice")
        expect(driver.fixture.filterOpens == 2 && driver.fixture.filterCloses == 2 && driver.fixture.noteOpens == 2,
            "A new invocation reacquires the actual selected filter proof once, then continues the unvisited candidate")
        expect(resumed.checkpoint?.scopeCapture != oldCapture, "Only this invocation's newly observed capture becomes its active scope")
        expect(try encoder.encode(resumed.pages) == oldPagesBytes, "Renewing current authority does not retroactively change old page proof or scope version")
        let finished = XiaohongshuCollectionStore(url: url), actions = driver.fixture.noteOpens + driver.fixture.filterOpens + driver.fixture.shareTaps
        driver.currentSort = .latest
        let unchangedCompleted = try await XiaohongshuCollector(store: finished).collect(task: request, driver: driver)
        expect(unchangedCompleted == resumed && actions == driver.fixture.noteOpens + driver.fixture.filterOpens + driver.fixture.shareTaps,
            "Already-completed runs return their historical result without new observation/input or scope relabeling")

        for mode in [XHSScopeRenewalReplay.CurrentSort.latest, .twoSelected, .duplicateOriginal] {
            let active = XHSScopeRenewalReplay(), activeStore = XiaohongshuCollectionStore(url: folder.appendingPathComponent("scope-active-\(checks).json"))
            active.onReturn = { active.currentSort = mode }
            let stopped = try await XiaohongshuCollector(store: activeStore).collect(task: task("active-\(checks)"), driver: active)
            expect(stopped.status == .paused && stopped.notes.count == 1, "A contradiction or multiple selected sorts during the current invocation overrides its earlier valid panel proof")
            expect(active.fixture.noteOpens == 1 && active.fixture.shareTaps == 1 && active.fixture.copyTaps == 1 && active.fixture.returns == 1,
                "Current ambiguous/contradictory selection never starts a second candidate or source transaction")
        }
        let merelyVisible = XHSScopeRenewalReplay(), visibleStore = XiaohongshuCollectionStore(url: folder.appendingPathComponent("scope-visible-latest.json"))
        merelyVisible.onReturn = { merelyVisible.currentSort = .visibleLatest }
        let visible = try await XiaohongshuCollector(store: visibleStore).collect(task: task("visible"), driver: merelyVisible)
        expect(visible.status == .sampleReached && visible.notes.count == 2, "A merely visible gray/unselected Latest label is not mistaken for a conflicting selected sort")

        let noteDriver = XHSScopeRenewalReplay(); noteDriver.fixture.mode = .note
        let noteStore = XiaohongshuCollectionStore(url: folder.appendingPathComponent("scope-initial-note.json"))
        let noteRun = try await XiaohongshuCollector(store: noteStore).collect(task: task("initial-note"), driver: noteDriver)
        expect(noteRun.status == .paused && noteRun.notes.isEmpty && noteRun.stopReason.hasPrefix("current_note_requires_fresh_collection_scope"), "A new invocation from a note requires the configured result/profile scope before adding any note")
        expect(noteDriver.fixture.noteOpens == 0 && noteDriver.fixture.returns == 0 && noteDriver.fixture.shareTaps == 0 && noteDriver.fixture.copyTaps == 0 && noteDriver.fixture.filterOpens == 0,
            "A note starting page does not trigger automatic Back, Share, Copy, candidate opening or option input")

        struct Document: Codable { var version = 1; var runs: [XiaohongshuCollectionRun] }
        for version in [1, 2] {
            var legacy = old
            legacy.pages[0].scopeVersion = version
            if version == 1 {
                legacy.pages[0].selectionEvidence = []; legacy.pages[0].screenshotSHA256 = nil; legacy.pages[0].scopeCapture = nil
                legacy.checkpoint?.scopeCapture = nil
            }
            let legacyPageBytes = try encoder.encode(legacy.pages), legacyURL = folder.appendingPathComponent("scope-legacy-v\(version).json")
            let legacyBytes = try encoder.encode(Document(runs: [legacy])); try legacyBytes.write(to: legacyURL, options: .atomic)
            let loaded = XiaohongshuCollectionStore(url: legacyURL)
            let loadedRun = try loaded.run(id: request.id)
            expect(loaded.error == nil && loadedRun == legacy, "A complete old scope-v\(version) document remains readable")
            let recheck = XHSScopeRenewalReplay()
            let renewed = try await XiaohongshuCollector(store: loaded).collect(task: request, driver: recheck)
            expect(renewed.status == .sampleReached && renewed.notes.count == 2 && recheck.fixture.filterOpens == 1 && recheck.fixture.noteOpens == 1,
                "Old scope-v\(version) renews actual current selection before accepting one additional unique source")
            expect(try encoder.encode(renewed.pages) == legacyPageBytes, "Old scope-v\(version) page evidence is not rewritten or upgraded into new current authority")
            let legacyReloaded = XiaohongshuCollectionStore(url: legacyURL)
            expect(try legacyReloaded.run(id: request.id) == renewed, "Mixed historical/current checkpoint evidence remains valid after old scope-v\(version) save and reload")
            if version == 1 {
                expect(try renewed.statistics().conditionEvidence.contains("legacy_visible_labels_only"), "Fresh verification does not retrospectively claim selected-state proof for old scope-v1 samples")
            }
        }
        return checks
    }
}
