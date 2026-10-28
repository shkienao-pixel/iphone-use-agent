import Foundation

/// Bounded share/copy/read transaction. It never invents an OCR URL and never
/// repeats Copy after an uncertain dispatch. Native I/O stays in the real driver.
@MainActor
enum XiaohongshuNavigationDriver {
    static func captureScope(task: XiaohongshuCollectionTask, results: XiaohongshuCollectionFrame,
                             driver: any XiaohongshuCollectionDriving,
                             read: @MainActor () async throws -> XiaohongshuCollectionFrame)
        async throws -> (restored: XiaohongshuCollectionFrame, capture: XiaohongshuScopeCapture) {
        guard let filter = XiaohongshuPageAdapter.filterControl(in: results.snapshot) else { throw XiaohongshuCollectionError.invalidObservation }
        try Task.checkCancellation(); try await driver.tapObserved(filter)
        let panel = try await read()
        guard XiaohongshuPageAdapter.identity(in: panel.snapshot)?.scene == "xiaohongshu.filters",
              let close = XiaohongshuPageAdapter.closeFilterControl(in: panel.snapshot) else {
            throw XiaohongshuCollectionError.invalidObservation
        }
        let matches = XiaohongshuPageAdapter.selected(task.sort, snapshot: panel.snapshot, evidence: panel.selectionEvidence,
                  screenshotSHA256: panel.screenshotSHA256, requiredRole: "sort") != nil,
            filtersMatch = task.filters.allSatisfy({ XiaohongshuPageAdapter.selected($0, snapshot: panel.snapshot, evidence: panel.selectionEvidence,
                screenshotSHA256: panel.screenshotSHA256, requiredRole: "filter") != nil })
        // Inspect current selection only; never change menu options to make a
        // task appear satisfied. Closing is itself an observed control.
        try Task.checkCancellation(); try await driver.tapObserved(close)
        let restored = try await read()
        guard matches && filtersMatch else {
            guard XiaohongshuPageAdapter.identity(in: restored.snapshot)?.scene == "xiaohongshu.results" else { throw XiaohongshuCollectionError.invalidObservation }
            throw XiaohongshuScopeError.selectionMismatch
        }
        let capture = XiaohongshuScopeCapture(resultsBefore: evidence(results), filterPanel: evidence(panel),
            resultsAfter: evidence(restored), selections: panel.selectionEvidence + XiaohongshuPageAdapter.explicitSelections(in: panel.snapshot),
            filterElementID: filter.id, closeElementID: close.id)
        try capture.validate(task: task)
        return (restored, capture)
    }
    struct Result {
        var source: XiaohongshuSource?
        var restored: XiaohongshuCollectionFrame
        var capture: XiaohongshuSourceCapture?
        var reason: String
    }
    static func evidence(_ frame: XiaohongshuCollectionFrame) -> XiaohongshuObservedPageEvidence {
        .init(snapshot: frame.snapshot, shareID: frame.shareID, width: frame.width, height: frame.height,
              screenshotSHA256: frame.screenshotSHA256, confirmedAt: frame.confirmedAt)
    }
    static func captureSource(note: XiaohongshuCollectionFrame, driver: any XiaohongshuCollectionDriving,
                              read: @MainActor () async throws -> XiaohongshuCollectionFrame,
                              saveAttempt: @MainActor (XiaohongshuSourceAttempt) throws -> Void) async throws -> Result {
        guard let share = XiaohongshuPageAdapter.shareControl(in: note.snapshot) else {
            return .init(source: nil, restored: note, capture: nil, reason: "missing_unique_visible_share_control")
        }
        let baseline: XiaohongshuClipboardSnapshot
        do { baseline = try await driver.clipboardSnapshot(readText: false) }
        catch XiaohongshuClipboardError.unsupported {
            return .init(source: nil, restored: note, capture: nil, reason: "controlled_share_clipboard_driver_unavailable")
        }
        guard baseline.changeCount >= 0 else { throw XiaohongshuCollectionError.invalidObservation }
        var attempt = XiaohongshuSourceAttempt(id: UUID(), note: evidence(note), stage: .openingShare,
            updatedAt: Date(), detail: "已保存分享意图；只点击当前唯一可见分享控件")
        try saveAttempt(attempt)
        do {
            try Task.checkCancellation()
            try await driver.tapObserved(share)
            let panel = try await read()
            guard XiaohongshuPageAdapter.identity(in: panel.snapshot)?.scene == "xiaohongshu.share",
                  let copy = XiaohongshuPageAdapter.copyLinkControl(in: panel.snapshot) else {
                throw XiaohongshuCollectionError.invalidObservation
            }
            attempt.stage = .copyPending; attempt.updatedAt = Date()
            attempt.detail = "复制链接派发前已保存；中断后不会自动重按复制"
            try saveAttempt(attempt)
            try Task.checkCancellation()
            try await driver.tapObserved(copy)
            var after = try await read()
            var changed = try await driver.clipboardSnapshot(readText: false)
            if changed.changeCount == baseline.changeCount {
                // One extra actual event/frame is allowed, never another tap.
                after = try await read()
                changed = try await driver.clipboardSnapshot(readText: false)
            }
            guard changed.changeCount > baseline.changeCount else { throw XiaohongshuClipboardError.unchanged }
            let restored: XiaohongshuCollectionFrame
            if XiaohongshuPageAdapter.identity(in: after.snapshot, noteOpenedFromResults: true)?.scene == "xiaohongshu.note" {
                restored = after
            } else if XiaohongshuPageAdapter.identity(in: after.snapshot)?.scene == "xiaohongshu.share",
                      let close = XiaohongshuPageAdapter.dismissShareControl(in: after.snapshot) {
                try Task.checkCancellation(); try await driver.tapObserved(close)
                restored = try await read()
            } else { throw XiaohongshuCollectionError.invalidObservation }
            guard XiaohongshuPageAdapter.identity(in: restored.snapshot, noteOpenedFromResults: true)?.scene == "xiaohongshu.note",
                  XiaohongshuPageAdapter.sameNoteText(note.snapshot, restored.snapshot) else {
                throw XiaohongshuCollectionError.invalidObservation
            }
            let capture = XiaohongshuSourceCapture(note: evidence(note), sharePanel: evidence(panel), afterCopy: evidence(after),
                restoredNote: evidence(restored), shareElementID: share.id, copyElementID: copy.id,
                baselineChangeCount: baseline.changeCount, copiedChangeCount: changed.changeCount,
                copiedAt: max(changed.readAt, restored.confirmedAt ?? restored.snapshot.capturedAt))
            try capture.validate()
            attempt.stage = .copiedAwaitingRead; attempt.capture = capture; attempt.updatedAt = Date()
            attempt.detail = "实际剪贴板变更次数已记录，来源文字尚待真实读取"
            try saveAttempt(attempt)
            do {
                let clipboard = try await driver.clipboardSnapshot(readText: true)
                let source = try await finish(capture: capture, clipboard: clipboard, resolveShortLink: driver.resolveShortLink)
                attempt.stage = .completed; attempt.updatedAt = Date(); attempt.detail = "已读取实际剪贴板并验证平台来源 ID"
                try saveAttempt(attempt)
                return .init(source: source, restored: restored, capture: capture, reason: "")
            } catch XiaohongshuClipboardError.foregroundRequired {
                return .init(source: nil, restored: restored, capture: capture, reason: "awaiting_foreground_copied_source_read")
            }
        } catch {
            attempt.stage = .uncertain; attempt.updatedAt = Date()
            attempt.detail = "分享/复制已开始但来源尚不确定；未自动重试：" + error.localizedDescription
            try? saveAttempt(attempt)
            throw error
        }
    }
    static func finish(capture: XiaohongshuSourceCapture, clipboard: XiaohongshuClipboardSnapshot,
                       resolveShortLink: @MainActor (URL) async throws -> XiaohongshuResolvedLink) async throws -> XiaohongshuSource {
        try capture.validate(); try Task.checkCancellation()
        guard clipboard.changeCount == capture.copiedChangeCount else { throw XiaohongshuClipboardError.changedAgain }
        guard clipboard.readAt >= capture.copiedAt, clipboard.readAt.timeIntervalSince(capture.copiedAt) <= 120,
              let text = clipboard.text, !text.isEmpty, text.utf8.count <= 16000,
              let copiedURL = XiaohongshuSource.copiedURL(in: text) else { throw XiaohongshuClipboardError.invalidLink }
        let resolution: XiaohongshuResolvedLink?
        let final: String
        if XiaohongshuSource.directURL(copiedURL.absoluteString) != nil { resolution = nil; final = copiedURL.absoluteString }
        else {
            guard XiaohongshuSource.isShortURL(copiedURL) else {
                throw XiaohongshuClipboardError.invalidLink
            }
            let resolved = try await resolveShortLink(copiedURL)
            try Task.checkCancellation(); try XiaohongshuSource.validateResolution(resolved, original: copiedURL)
            resolution = resolved; final = resolved.finalURL
        }
        guard let parsed = XiaohongshuSource.directURL(final) else { throw XiaohongshuClipboardError.invalidLink }
        let source = XiaohongshuSource(noteID: parsed.noteID, url: parsed.url, evidenceElementID: capture.copyElementID,
            observedText: text, shareCapture: capture, clipboard: clipboard, resolvedLink: resolution)
        try source.validate(in: capture.note.snapshot.elements)
        return source
    }
}
