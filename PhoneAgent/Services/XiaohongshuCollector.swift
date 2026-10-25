import Foundation

struct XiaohongshuCollectionFrame {
    var snapshot: PhoneUISnapshot
    var shareID: String
    var width: Int
    var height: Int
    var selectionEvidence: [XiaohongshuSelectionEvidence] = []
    var screenshotSHA256: String? = nil
    var confirmedAt: Date? = nil
    var scopeCapture: XiaohongshuScopeCapture? = nil
}

/// The production runtime bridges these four operations to current OCR/frames
/// and observed bounds. Tests inject the same boundary, not an alternate engine.
@MainActor
protocol XiaohongshuCollectionDriving {
    func read() async throws -> XiaohongshuCollectionFrame
    func openNote(_ element: PhoneUIElement) async throws
    func returnToResults() async throws
    func scrollResults(at element: PhoneUIElement) async throws
    func tapObserved(_ element: PhoneUIElement) async throws
    func clipboardSnapshot(readText: Bool) async throws -> XiaohongshuClipboardSnapshot
    func resolveShortLink(_ url: URL) async throws -> XiaohongshuResolvedLink
}
extension XiaohongshuCollectionDriving {
    func tapObserved(_ element: PhoneUIElement) async throws { throw XiaohongshuClipboardError.unsupported }
    func clipboardSnapshot(readText: Bool) async throws -> XiaohongshuClipboardSnapshot { throw XiaohongshuClipboardError.unsupported }
    func resolveShortLink(_ url: URL) async throws -> XiaohongshuResolvedLink { throw XiaohongshuClipboardError.unsupported }
}

private enum XiaohongshuReadingBudgetError: Error { case exhausted }

/// Observations may finish after the budget boundary, but no further GUI input
/// may start. The same guard also covers Share/Copy/Back inside navigation.
@MainActor private final class BudgetedXiaohongshuDriver: XiaohongshuCollectionDriving {
    let base: any XiaohongshuCollectionDriving
    let requireBudget: @MainActor () throws -> Void
    init(base: any XiaohongshuCollectionDriving, requireBudget: @escaping @MainActor () throws -> Void) {
        self.base = base; self.requireBudget = requireBudget
    }
    func read() async throws -> XiaohongshuCollectionFrame { try await base.read() }
    func openNote(_ element: PhoneUIElement) async throws { try requireBudget(); try await base.openNote(element) }
    func returnToResults() async throws { try requireBudget(); try await base.returnToResults() }
    func scrollResults(at element: PhoneUIElement) async throws { try requireBudget(); try await base.scrollResults(at: element) }
    func tapObserved(_ element: PhoneUIElement) async throws { try requireBudget(); try await base.tapObserved(element) }
    func clipboardSnapshot(readText: Bool) async throws -> XiaohongshuClipboardSnapshot { try await base.clipboardSnapshot(readText: readText) }
    func resolveShortLink(_ url: URL) async throws -> XiaohongshuResolvedLink { try await base.resolveShortLink(url) }
}

@MainActor
final class XiaohongshuCollector {
    private let store: XiaohongshuCollectionStore
    private let clock: @MainActor () -> TimeInterval
    private var collecting = false
    init(store: XiaohongshuCollectionStore, clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.store = store; self.clock = clock
    }

    /// Called from the phone app's foreground UI after a background pasteboard
    /// read was denied. The exact post-Copy changeCount must still match.
    func completeCopiedSource(taskID: String, clipboard: XiaohongshuClipboardSnapshot,
                              resolveShortLink: @MainActor (URL) async throws -> XiaohongshuResolvedLink) async throws -> XiaohongshuCollectionRun {
        guard !collecting, let original = try store.run(id: taskID) else { throw XiaohongshuCollectionError.invalidTask }
        collecting = true; defer { collecting = false }
        let pending = original.pending.filter { $0.sourceCapture != nil }
        guard pending.count == 1, let value = pending.first, let capture = value.sourceCapture else {
            throw XiaohongshuCollectionError.invalidTask
        }
        let source = try await XiaohongshuNavigationDriver.finish(capture: capture, clipboard: clipboard, resolveShortLink: resolveShortLink)
        try Task.checkCancellation()
        // Resolving a short link yields the actor. Keep intervening analysis and
        // progress, and bind this result only to the same immutable pending row.
        guard var run = try store.run(id: taskID), run.task == original.task,
              run.pending.first(where: { $0.id == value.id }) == value else {
            throw XiaohongshuCollectionError.changedEvidence
        }
        let snapshot = capture.note.snapshot
        guard let identity = XiaohongshuPageAdapter.identity(in: snapshot, noteOpenedFromResults: true),
              let note = Self.extractNote(snapshot: snapshot, identity: identity, task: run.task, source: source).note else {
            throw XiaohongshuCollectionError.invalidObservation
        }
        if let index = run.notes.firstIndex(where: { $0.id == note.id }) {
            // An older pending capture must not replace a note added or changed
            // while resolving, or one observed after that pending capture.
            guard original.notes.first(where: { $0.id == note.id }) == run.notes[index],
                  run.notes[index].observedAt <= note.observedAt else {
                throw XiaohongshuCollectionError.changedEvidence
            }
            run.duplicateObservations += 1
            if run.notes[index].visibleTextSHA256 != note.visibleTextSHA256 {
                run.noteRevisions.append(run.notes[index]); run.notes[index] = note
            }
        } else { run.notes.append(note) }
        run.pending.removeAll { $0.id == value.id }
        for index in run.sourceAttempts.indices where run.sourceAttempts[index].capture == capture {
            run.sourceAttempts[index].stage = .completed; run.sourceAttempts[index].updatedAt = Date()
            run.sourceAttempts[index].detail = "前台实际读取同一剪贴板变更的来源，未重按分享或复制"
        }
        run.updatedAt = Date()
        run.status = run.notes.count >= run.task.sampleSize ? .sampleReached : .paused
        run.stopReason = run.status == .sampleReached ? "sample_reached" : "source_completed; resume_from_verified_results"
        try store.save(run); return run
    }

    func collect(task: XiaohongshuCollectionTask, driver originalDriver: any XiaohongshuCollectionDriving) async throws -> XiaohongshuCollectionRun {
        try task.validate()
        guard !collecting else { throw XiaohongshuCollectionError.invalidTask }
        collecting = true; defer { collecting = false }
        var run = try store.run(id: task.id) ?? XiaohongshuCollectionRun(task: task, startedAt: Date(), updatedAt: Date())
        guard run.task == task else { throw XiaohongshuCollectionError.conflictingTask }
        if run.status == .sampleReached { return run }
        if run.sourceAttempts.contains(where: { $0.stage == .copyPending || $0.stage == .uncertain || $0.stage == .copiedAwaitingRead }) {
            run.status = .paused; run.stopReason = "source_copy_pending_review; do not replay share/copy"
            run.updatedAt = Date(); try store.save(run); return run
        }
        let started = clock(), previousElapsed = run.checkpoint?.elapsedSeconds ?? 0
        func elapsed() -> TimeInterval { previousElapsed + max(0, clock() - started) }
        func requireBudget() throws {
            try Task.checkCancellation()
            guard elapsed() < task.stops.maxSeconds else { throw XiaohongshuReadingBudgetError.exhausted }
        }
        let driver = BudgetedXiaohongshuDriver(base:originalDriver, requireBudget:requireBudget)
        let originalCheckpoint = run.checkpoint
        // Persisted captures remain historical evidence, never authority for a
        // new invocation: the user may have changed selection while paused.
        var activeScopeCapture: XiaohongshuScopeCapture?
        run.status = .running; run.stopReason = ""
        func persist() throws {
            run.updatedAt = Date()
            run.checkpoint?.elapsedSeconds = elapsed()
            try store.save(run)
        }
        func stop(_ status: XiaohongshuCollectionRun.Status, _ reason: String) throws -> XiaohongshuCollectionRun {
            run.status = status; run.stopReason = reason
            run.events.append(.init(at: Date(), kind: "stop", detail: reason))
            try persist(); return run
        }
        func bounded() -> String? {
            if run.notes.count >= task.sampleSize { return "sample_reached" }
            if (run.checkpoint?.attemptedNotes ?? 0) >= task.stops.maxNotes { return "max_note_attempts" }
            if elapsed() >= task.stops.maxSeconds { return "max_seconds" }
            return nil
        }
        func read() async throws -> XiaohongshuCollectionFrame {
            try Task.checkCancellation()
            var value = try await driver.read()
            value.scopeCapture = activeScopeCapture
            try Task.checkCancellation()
            guard value.width > 0, value.height > 0, !value.shareID.isEmpty,
                  !value.snapshot.deviceKey.isEmpty, !value.snapshot.blockingOverlay,
                  value.snapshot.elements.count <= 4000, value.snapshot.elements.allSatisfy({ $0.rect.valid }),
                  Set(value.snapshot.elements.map(\.id)).count == value.snapshot.elements.count,
                  value.snapshot.capturedAt.timeIntervalSince1970.isFinite,
                  abs(Date().timeIntervalSince(value.confirmedAt ?? value.snapshot.capturedAt)) <= 30 else {
                throw XiaohongshuCollectionError.invalidObservation
            }
            if let check = run.checkpoint {
                guard value.shareID == check.shareID, value.snapshot.deviceKey == check.deviceKey,
                      value.width == check.width, value.height == check.height else {
                    throw XiaohongshuCollectionError.invalidObservation
                }
            }
            run.checkpoint?.readCount += 1
            return value
        }
        do {
            try Task.checkCancellation()
            try requireBudget()
            // Bind to a fresh actual frame. Resuming on a new share/size requires
            // a verified results scope and discards old viewport coordinates.
            let previous = run.checkpoint
            run.checkpoint = nil
            var current = try await read()
            let firstIdentity = XiaohongshuPageAdapter.identity(in: current.snapshot, noteOpenedFromResults: previous?.viewport.isEmpty == false)
            if let previous, previous.deviceKey != current.snapshot.deviceKey {
                run.checkpoint = previous
                return try stop(.paused, "device_changed; use a new task for a different phone")
            }
            if firstIdentity?.scene == "xiaohongshu.note" {
                run.checkpoint = previous
                return try stop(.paused, "current_note_requires_fresh_collection_scope; 请先回到已配置的搜索结果或作者主页核验当前选中条件；没有自动返回、分享或新增笔记")
            }
            if Self.isCollectionPage(firstIdentity?.scene, task: task), Self.hasContradictoryCurrentSort(task: task, frame: current) {
                run.checkpoint = previous
                return try stop(.paused, "current_sort_conflicts_or_is_ambiguous; 当前选中排序与任务不一致或不唯一，没有修改选项或开始采集")
            }
            if task.range == "currentSearchResults", firstIdentity?.scene == "xiaohongshu.results",
               Self.queryEvidence(task: task, snapshot: current.snapshot) != nil,
               Self.scopeEvidence(task: task, frame: current) == nil,
               XiaohongshuPageAdapter.filterControl(in: current.snapshot) != nil {
                let scoped = try await XiaohongshuNavigationDriver.captureScope(task: task, results: current, driver: driver, read: read)
                activeScopeCapture = scoped.capture; current = scoped.restored; current.scopeCapture = scoped.capture
            }
            let firstScope = Self.scopeEvidence(task: task, frame: current)
            if let previous, previous.shareID != current.shareID || previous.width != current.width || previous.height != current.height {
                guard Self.isCollectionPage(firstIdentity?.scene, task: task), firstScope != nil else {
                    run.checkpoint = previous
                    return try stop(.paused, "resume_needs_verified_results_after_share_or_size_change")
                }
                run.checkpoint = XiaohongshuCollectionCheckpoint(deviceKey: current.snapshot.deviceKey,
                    shareID: current.shareID, width: current.width, height: current.height,
                    attemptedNotes: previous.attemptedNotes, readCount: previous.readCount + 1,
                    scrollCount: previous.scrollCount, noteOpenCount: previous.noteOpenCount,
                    elapsedSeconds: previous.elapsedSeconds)
                run.events.append(.init(at: Date(), kind: "resume_rebind", detail: "重新核验搜索条件，清除旧视口坐标；笔记 ID 去重明细保留"))
            } else {
                run.checkpoint = previous ?? XiaohongshuCollectionCheckpoint(deviceKey: current.snapshot.deviceKey,
                    shareID: current.shareID, width: current.width, height: current.height)
                run.checkpoint?.readCount += 1
            }
            // Keep the old raw capture available for audit when the current
            // page proves selection directly. read() only uses this invocation's
            // activeScopeCapture and never promotes this historical field.
            run.checkpoint?.scopeCapture = activeScopeCapture ?? previous?.scopeCapture
            try persist()
            var newPageAfterScroll = false
            while true {
                try Task.checkCancellation()
                if let reason = bounded() { return try stop(reason == "sample_reached" ? .sampleReached : .boundedStop, reason) }
                guard let identity = XiaohongshuPageAdapter.identity(in: current.snapshot, noteOpenedFromResults: run.checkpoint?.viewport.isEmpty == false) else {
                    return try stop(.paused, "unknown_page_identity; no guessed navigation")
                }
                if identity.scene == "xiaohongshu.note" {
                    // This invocation opened the note after its current scope
                    // check. A later invocation must first reverify results.
                    if run.checkpoint?.viewport.isEmpty != false {
                        return try stop(.paused, "note_without_verified_search_scope; open requested search results")
                    }
                    run.checkpoint?.attemptedNotes += 1
                    var extracted = Self.extractNote(snapshot: current.snapshot, identity: identity, task: task)
                    var pendingCapture: XiaohongshuSourceCapture?
                    var pendingAlreadyStored = false
                    if extracted.note == nil && extracted.reason.hasPrefix("missing_platform_note_url") {
                        // Save raw evidence before opening Share. An interruption
                        // cannot erase the note or silently repeat Copy.
                        let rawID = UUID()
                        run.pending.append(.init(id: rawID, observedAt: current.snapshot.capturedAt,
                            reason: "source_capture_started", elements: current.snapshot.elements, pageScene: identity.scene))
                        pendingAlreadyStored = true
                        try persist()
                        let captured = try await XiaohongshuNavigationDriver.captureSource(note: current, driver: driver, read: read,
                            saveAttempt: { attempt in
                                if let index = run.sourceAttempts.firstIndex(where: { $0.id == attempt.id }) { run.sourceAttempts[index] = attempt }
                                else { run.sourceAttempts.append(attempt) }
                                try persist()
                            })
                        pendingCapture = captured.capture
                        if let source = captured.source {
                            extracted = Self.extractNote(snapshot: current.snapshot, identity: identity, task: task, source: source)
                            run.pending.removeAll { $0.id == rawID }
                        } else {
                            let index = run.pending.firstIndex { $0.id == rawID }!
                            run.pending[index].reason = captured.reason; run.pending[index].sourceCapture = captured.capture
                            extracted.reason = captured.reason
                        }
                        current = captured.restored
                    }
                    if let note = extracted.note {
                        if let index = run.notes.firstIndex(where: { $0.id == note.id }) {
                            run.duplicateObservations += 1
                            // Preserve revisions while keeping one latest row
                            // per platform ID for reproducible current statistics.
                            let old = run.notes[index]
                            if old.visibleTextSHA256 != note.visibleTextSHA256 || old.likes != note.likes ||
                                old.favorites != note.favorites || old.comments != note.comments {
                                run.noteRevisions.append(old)
                                run.notes[index] = note
                                run.events.append(.init(at: Date(), kind: "note_revision", detail: note.id + ": prior evidence retained; latest display used"))
                            }
                        } else { run.notes.append(note) }
                    } else if !pendingAlreadyStored {
                        run.pending.append(.init(id: UUID(), observedAt: current.snapshot.capturedAt,
                            reason: extracted.reason, elements: current.snapshot.elements, pageScene: identity.scene, sourceCapture: pendingCapture))
                    }
                    // Persist the raw batch BEFORE any scroll/back operation.
                    try persist()
                    if pendingCapture != nil && extracted.note == nil {
                        return try stop(.paused, extracted.reason)
                    }
                    if let reason = bounded() { return try stop(reason == "sample_reached" ? .sampleReached : .boundedStop, reason) }
                    try Task.checkCancellation()
                    try await driver.returnToResults()
                    current = try await read()
                    guard Self.isCollectionPage(XiaohongshuPageAdapter.identity(in: current.snapshot)?.scene, task: task),
                          Self.scopeEvidence(task: task, frame: current) != nil else {
                        return try stop(.paused, "back_did_not_restore_requested_results")
                    }
                    continue
                }
                guard Self.isCollectionPage(identity.scene, task: task),
                      let scopeEvidence = Self.scopeEvidence(task: task, frame: current) else {
                    return try stop(.paused, "search_scope_unverified; actual selected sort/filters and query/profile evidence required")
                }
                let signature = Self.viewport(current.snapshot)
                if run.pages.isEmpty || run.checkpoint?.viewport != signature || newPageAfterScroll {
                    guard run.pages.count < task.stops.maxPages else { return try stop(.boundedStop, "max_pages") }
                    let repeated = run.checkpoint?.viewport == signature && !run.pages.isEmpty
                    run.pages.append(.init(number: run.pages.count + 1, observedAt: current.snapshot.capturedAt,
                        viewport: signature, elementCount: current.snapshot.elements.count, scopeEvidence: scopeEvidence,
                        elements: current.snapshot.elements, selectionEvidence: current.selectionEvidence + XiaohongshuPageAdapter.explicitSelections(in: current.snapshot),
                        screenshotSHA256: current.screenshotSHA256,
                        scopeVersion: XiaohongshuPageAdapter.nativeLatestLayout(in: current.snapshot) == nil ? 2 : 3,
                        scopeCapture: current.scopeCapture))
                    let pageStartUniqueCount = run.notes.count
                    run.checkpoint?.viewport = signature
                    run.checkpoint?.visitedCandidateKeys = []
                    run.checkpoint?.pageStartUniqueCount = pageStartUniqueCount
                    run.checkpoint?.pageRepeatedViewport = repeated
                    newPageAfterScroll = false
                    try persist()
                }
                let visited = Set(run.checkpoint?.visitedCandidateKeys ?? [])
                let candidates = Self.candidates(in: current.snapshot, task: task)
                if let candidate = candidates.first(where: { !visited.contains(Self.candidateKey($0)) }) {
                    run.checkpoint?.visitedCandidateKeys.append(Self.candidateKey(candidate))
                    run.checkpoint?.noteOpenCount += 1
                    // Persist the attempt before UI input, so interruption does
                    // not replay a stale candidate without another observation.
                    try persist()
                    try Task.checkCancellation()
                    try await driver.openNote(candidate)
                    current = try await read()
                    guard XiaohongshuPageAdapter.identity(in: current.snapshot, noteOpenedFromResults: true)?.scene == "xiaohongshu.note" else {
                        return try stop(.paused, "candidate_did_not_open_note; fresh inspection required")
                    }
                    continue
                }
                if run.checkpoint?.pageRepeatedViewport == true {
                    if run.notes.count == run.checkpoint?.pageStartUniqueCount {
                        run.checkpoint?.repeatedPages += 1
                    } else { run.checkpoint?.repeatedPages = 0 }
                    if (run.checkpoint?.repeatedPages ?? 0) >= task.stops.maxRepeatedPages {
                        return try stop(.boundedStop, "repeated_viewport; no new source IDs within bounded repeated pages")
                    }
                } else { run.checkpoint?.repeatedPages = 0 }
                if run.pages.count >= task.stops.maxPages { return try stop(.boundedStop, "max_pages") }
                // Reuse this observation's list bounds, never the pointer left
                // on Back/Share. No observed list item means no scroll target.
                guard let scrollTarget = candidates.first else {
                    return try stop(.paused, "scroll_target_unavailable; inspect current results before continuing")
                }
                try Task.checkCancellation()
                run.checkpoint?.scrollCount += 1
                try persist()
                try await driver.scrollResults(at: scrollTarget)
                let after = try await read()
                guard Self.isCollectionPage(XiaohongshuPageAdapter.identity(in: after.snapshot)?.scene, task: task),
                      Self.scopeEvidence(task: task, frame: after) != nil else {
                    return try stop(.paused, "scroll_changed_page_or_scope")
                }
                // Identical OCR on another page may be distinct notes. Reopen
                // observed candidates and compare actual source IDs before
                // declaring a repeated page; title/text cannot deduplicate.
                newPageAfterScroll = true
                current = after
            }
        } catch XiaohongshuReadingBudgetError.exhausted {
            if run.checkpoint == nil { run.checkpoint = originalCheckpoint }
            return try stop(.boundedStop, "max_seconds")
        } catch XiaohongshuScopeError.selectionMismatch {
            if run.checkpoint == nil { run.checkpoint = originalCheckpoint }
            return try stop(.paused, XiaohongshuScopeError.selectionMismatch.localizedDescription)
        } catch XiaohongshuClipboardError.unsupported {
            if run.checkpoint == nil { run.checkpoint = originalCheckpoint }
            return try stop(.paused, "selected_scope_requires_controlled_filter_driver")
        } catch is CancellationError {
            if run.checkpoint == nil { run.checkpoint = originalCheckpoint }
            _ = try? stop(.cancelled, "cancelled; persisted ID-deduplicated batches retained")
            throw CancellationError()
        } catch {
            if run.checkpoint == nil { run.checkpoint = originalCheckpoint }
            _ = try? stop(.failed, error.localizedDescription)
            throw error
        }
    }

    static func scopeEvidence(task: XiaohongshuCollectionTask, snapshot: PhoneUISnapshot) -> [String]? {
        scopeEvidence(task: task, frame: .init(snapshot: snapshot, shareID: "scope-only", width: 1, height: 1))
    }
    static func isCollectionPage(_ scene: String?, task: XiaohongshuCollectionTask) -> Bool {
        scene == (task.range == "currentProfileNotes" ? "xiaohongshu.profile" : "xiaohongshu.results")
    }
    static func scopeEvidence(task: XiaohongshuCollectionTask, frame: XiaohongshuCollectionFrame) -> [String]? {
        let snapshot = frame.snapshot
        guard isCollectionPage(XiaohongshuPageAdapter.identity(in: snapshot)?.scene, task: task) else { return nil }
        var evidence: [String] = []
        if task.range == "currentProfileNotes" {
            guard let profileID = task.profileID else { return nil }
            let matches = snapshot.elements.filter { element in
                guard element.source == "ocr", element.rect.centerY < 0.5 else { return false }
                let raw = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
                for prefix in ["小红书号：", "小红书号:", "REDnote ID:", "Rednote ID:", "rednote id:"] where raw.hasPrefix(prefix) {
                    return String(raw.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) == profileID
                }
                guard let url = URL(string: raw), XiaohongshuSource.permittedURL(url), url.scheme == "https",
                      ["xiaohongshu.com", "www.xiaohongshu.com"].contains(url.host?.lowercased() ?? "") else { return false }
                return url.path == "/user/profile/" + profileID
            }
            guard matches.count == 1, let selected = XiaohongshuPageAdapter.selected("笔记", snapshot: snapshot,
                evidence: frame.selectionEvidence, screenshotSHA256: frame.screenshotSHA256) ??
                XiaohongshuPageAdapter.selected("notes", snapshot: snapshot, evidence: frame.selectionEvidence, screenshotSHA256: frame.screenshotSHA256) else { return nil }
            evidence = [matches[0].id] + selected
        } else {
            guard let query = queryEvidence(task: task, snapshot: snapshot) else { return nil }
            guard !hasContradictoryCurrentSort(task: task, frame: frame) else { return nil }
            if XiaohongshuPageAdapter.nativeLatestLayout(in: snapshot) != nil {
                guard XiaohongshuPageAdapter.sortKey(task.sort) == "latest", task.filters.isEmpty,
                      let native = XiaohongshuPageAdapter.nativeLatestScopeEvidence(snapshot: snapshot,
                        evidence: frame.selectionEvidence, screenshotSHA256: frame.screenshotSHA256) else { return nil }
                return query + native
            }
            if let capture = frame.scopeCapture, (try? capture.validate(task: task)) != nil,
               capture.resultsAfter.shareID == frame.shareID, capture.resultsAfter.snapshot.deviceKey == snapshot.deviceKey,
               capture.resultsAfter.width == frame.width, capture.resultsAfter.height == frame.height,
               let filter = XiaohongshuPageAdapter.filterControl(in: snapshot) {
                return query + [filter.id]
            }
            guard let selected = XiaohongshuPageAdapter.selected(task.sort, snapshot: snapshot,
                evidence: frame.selectionEvidence, screenshotSHA256: frame.screenshotSHA256, requiredRole: "sort") else { return nil }
            evidence = query + selected
        }
        for text in task.filters {
            guard let selected = XiaohongshuPageAdapter.selected(text, snapshot: snapshot,
                evidence: frame.selectionEvidence, screenshotSHA256: frame.screenshotSHA256) else { return nil }
            evidence += selected
        }
        return evidence
    }
    /// Only independently valid CURRENT selection evidence with an actual sort
    /// role participates. Visible category labels or a gray Latest chip are not
    /// selected-sort proof. Duplicate proofs for one element are harmless;
    /// multiple selected sort elements, even with the same label, are ambiguous.
    private static func hasContradictoryCurrentSort(task: XiaohongshuCollectionTask, frame: XiaohongshuCollectionFrame) -> Bool {
        guard task.range == "currentSearchResults" else { return false }
        let snapshot = frame.snapshot
        var observed: [String: String] = [:]
        for value in frame.selectionEvidence + XiaohongshuPageAdapter.explicitSelections(in: snapshot) {
            guard let element = snapshot.element(id: value.elementID), element.source == "ocr", element.rect.valid,
                  XiaohongshuPageAdapter.selectionRole(element, snapshot: snapshot) == "sort",
                  XiaohongshuPageAdapter.selected(value.label, snapshot: snapshot, evidence: [value],
                    screenshotSHA256: frame.screenshotSHA256, requiredRole: "sort", allowExplicit: false) != nil else { continue }
            observed[element.id] = XiaohongshuPageAdapter.sortKey(value.label)
        }
        return !observed.isEmpty && (observed.count != 1 || observed.values.first != XiaohongshuPageAdapter.sortKey(task.sort))
    }
    static func queryEvidence(task: XiaohongshuCollectionTask, snapshot: PhoneUISnapshot) -> [String]? {
        let query = snapshot.elements.filter { element in
            guard element.source == "ocr", element.rect.centerY < 0.18 else { return false }
            let label = PhonePageAdapters.normalized(element.label), expected = PhonePageAdapters.normalized(task.keyword)
            return [expected, "搜索：" + expected, "搜索:" + expected, "search: " + expected].contains(label)
        }
        return query.count == 1 ? [query[0].id] : nil
    }

    /// These are observation-backed candidates, not permanent note identities.
    /// Opening one must yield a positively identified note page before extraction.
    static func candidates(in snapshot: PhoneUISnapshot, task: XiaohongshuCollectionTask) -> [PhoneUIElement] {
        let excluded = Set(([task.keyword, task.sort] + task.filters + ["小红书", "xiaohongshu", "rednote", "综合", "全部", "用户", "商品", "筛选", "搜索", "取消", "最新", "最热", "热门", "关注", "发现", "附近", "消息", "我", "笔记", "收藏", "赞过", "notes", "saved", "liked", "all", "users", "products", "images", "top", "latest", "search", "ask dots", "ai answered for you"]).map(XiaohongshuPageAdapter.baseLabel))
        let profileTabs = snapshot.elements.filter { ["笔记", "收藏", "赞过", "notes", "saved", "liked"].contains(XiaohongshuPageAdapter.baseLabel($0.label)) && $0.rect.centerY < 0.72 }
        let native = task.range == "currentSearchResults" ? XiaohongshuPageAdapter.nativeLatestLayout(in: snapshot) : nil
        let minimumY = native?.contentBeginsAt ?? (task.range == "currentProfileNotes" ? (profileTabs.map { $0.rect.y + $0.rect.height }.max() ?? 0.7) + 0.02 : 0.34)
        let maximumY = native == nil ? 0.82 : 0.94
        return snapshot.elements.filter {
            let label = $0.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return $0.source == "ocr" && $0.rect.valid && $0.rect.centerY >= minimumY && $0.rect.centerY <= maximumY &&
                label.count >= 3 && label.count <= 300 && !excluded.contains(XiaohongshuPageAdapter.baseLabel(label)) &&
                XiaohongshuObservedCount.parse(label).kind == .unknown && !label.hasPrefix("http")
        }.sorted { lhs, rhs in
            if abs(lhs.rect.y - rhs.rect.y) > 0.04 { return lhs.rect.y < rhs.rect.y }
            return lhs.rect.x < rhs.rect.x
        }
    }

    static func candidateKey(_ element: PhoneUIElement) -> String {
        element.label + "@" + [element.rect.x, element.rect.y, element.rect.width, element.rect.height]
            .map { String(format: "%.2f", $0) }.joined(separator: ",")
    }
    static func viewport(_ snapshot: PhoneUISnapshot) -> String {
        // This full, reversible OCR signature is only an overlap/scroll anchor.
        // It is not exported as a platform identity or used to merge notes.
        snapshot.elements.filter { $0.source == "ocr" && (0.34...0.82).contains($0.rect.centerY) }
            .sorted { $0.rect.y == $1.rect.y ? $0.rect.x < $1.rect.x : $0.rect.y < $1.rect.y }
            .map(candidateKey).joined(separator: "\n")
    }

    static func extractNote(snapshot: PhoneUISnapshot, identity: PhonePageIdentity, task: XiaohongshuCollectionTask, source overrideSource: XiaohongshuSource? = nil)
        -> (note: XiaohongshuNoteObservation?, reason: String) {
        guard identity.scene == "xiaohongshu.note", XiaohongshuPageAdapter.identity(in: snapshot, noteOpenedFromResults: true) == identity else {
            return (nil, "actual_note_page_not_identified")
        }
        let sources = overrideSource.map { [$0] } ?? snapshot.elements.compactMap(XiaohongshuSource.extract)
        let ids = Set(sources.map(\.noteID))
        guard ids.count == 1, let source = sources.first else {
            return (nil, sources.isEmpty ? "missing_platform_note_url; not a unique sample" : "ambiguous_platform_note_urls; not a unique sample")
        }
        let title = XiaohongshuNoteEvidence.labelled(XiaohongshuNoteEvidence.titlePrefixes, elements: snapshot.elements)
        let body = XiaohongshuNoteEvidence.body(elements: snapshot.elements)
        // Author is only assigned from an explicit label. A nearby display name
        // without a reliable role stays as raw OCR evidence, not guessed metadata.
        let author = XiaohongshuNoteEvidence.labelled(XiaohongshuNoteEvidence.authorPrefixes, elements: snapshot.elements)
        let actualText = snapshot.elements.filter { $0.source == "ocr" }.map(\.label).joined(separator: "\n")
        let keywordMatches = actualText.range(of: task.keyword, options: [.caseInsensitive, .diacriticInsensitive]) == nil ? [] : [task.keyword]
        let note = XiaohongshuNoteObservation(source: source, observedAt: snapshot.capturedAt,
            pageScene: identity.scene, pageEvidence: identity.evidence, elements: snapshot.elements,
            matchedKeywords: keywordMatches, title: task.fields.contains(.title) ? title : nil,
            body: task.fields.contains(.body) ? body : nil, author: task.fields.contains(.author) ? author : nil,
            likes: task.fields.contains(.likes) ? XiaohongshuNoteEvidence.count(XiaohongshuNoteEvidence.likeLabels, elements: snapshot.elements) : .unknown,
            favorites: task.fields.contains(.favorites) ? XiaohongshuNoteEvidence.count(XiaohongshuNoteEvidence.favoriteLabels, elements: snapshot.elements) : .unknown,
            comments: task.fields.contains(.comments) ? XiaohongshuNoteEvidence.count(XiaohongshuNoteEvidence.commentLabels, elements: snapshot.elements) : .unknown,
            pageAdapterVersion: 2)
        return (note, "")
    }
}
