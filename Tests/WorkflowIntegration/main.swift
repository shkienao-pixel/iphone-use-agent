import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class CaptureReplay {
    let stream = UUID()
    let capture = CaptureService()
    let executor = MouseExecutor()
    var observations: [Date: [PhoneUIElement]] = [:]
    var queue: [[PhoneUIElement]] = []
    var recognitions = 0
    var nextCalls = 0
    private var lastDelivered = Date.distantPast
    private(set) var clockRetries = 0
    var onRecognize: (() async throws -> Void)?
    let folder: URL
    init(folder: URL) { self.folder = folder }
    lazy var harness = PhoneHarnessRuntime(executor: executor, memoryURL: folder.appendingPathComponent(UUID().uuidString + ".json"),
        recognize: { frame in
            self.recognitions += 1
            try await self.onRecognize?()
            guard let elements = self.observations[frame.capturedAt] else { throw AgentError.message("missing recorded OCR fixture") }
            return elements
        })
    func frame(_ elements: [PhoneUIElement], stream: UUID? = nil, at: Date = Date()) -> ScreenFrame {
        var frame = ScreenFrame(capturedAt: at, captureID: stream ?? self.stream)
        let jpeg=NSMutableData()
        let destination=CGImageDestinationCreateWithData(jpeg,UTType.jpeg.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(destination,frame.image.cgImage!,nil)
        precondition(CGImageDestinationFinalize(destination));frame.jpeg=jpeg as Data
        observations[at] = elements
        return frame
    }
    private func freshDate(after boundary: Date, context: String) throws -> Date {
        let started = ProcessInfo.processInfo.systemUptime
        while true {
            let now = Date()
            if now > boundary { return now }
            guard ProcessInfo.processInfo.systemUptime - started < 1 else {
                let details: [String: Any] = ["fixture": "CaptureReplay", "context": context,
                    "error": "Real clock did not advance beyond the required boundary within one monotonic second",
                    "boundary": boundary.timeIntervalSinceReferenceDate, "actualNow": now.timeIntervalSinceReferenceDate,
                    "boundaryBits": String(boundary.timeIntervalSinceReferenceDate.bitPattern),
                    "actualNowBits": String(now.timeIntervalSinceReferenceDate.bitPattern), "clockRetries": clockRetries,
                    "nextCalls": nextCalls, "queueCount": queue.count]
                if let data = try? JSONSerialization.data(withJSONObject: details, options: [.sortedKeys]) {
                    FileHandle.standardError.write(data); FileHandle.standardError.write(Data("\n".utf8))
                }
                throw AgentError.message("CaptureReplay real clock did not advance; no future timestamp or queued frame was invented")
            }
            clockRetries += 1
            Thread.sleep(forTimeInterval: 0.0001)
        }
    }
    func show(_ elements: [PhoneUIElement], stream: UUID? = nil, at: Date? = nil) -> ScreenFrame {
        let entered = Date()
        let deliveredAt: Date
        if let at { deliveredAt = at } // Deliberately stale/explicit fixtures retain their exact original time.
        else {
            do { deliveredAt = try freshDate(after: max(entered, lastDelivered), context: "default show") }
            catch { preconditionFailure(error.localizedDescription) }
        }
        let frame = frame(elements, stream: stream, at: deliveredAt)
        capture.frozenFrame = frame; lastDelivered = max(lastDelivered, deliveredAt)
        return frame
    }
    func next(_ after: Date) throws -> ScreenFrame {
        nextCalls += 1
        guard !queue.isEmpty else { throw AgentError.message("capture replay exhausted") }
        // A real callback must cross the caller's actual input boundary before
        // consuming a queued page. Never add an epsilon/future timestamp, and
        // never relax the production driver's strict timestamp comparison.
        let deliveredAt = try freshDate(after: max(after, max(Date(), lastDelivered)), context: "next(after:)")
        return show(queue.removeFirst(), at: deliveredAt)
    }
    func driver(initial: ScreenFrame? = nil) -> PhoneWorkflowCaptureDriver {
        PhoneWorkflowCaptureDriver(capture: capture, executor: executor, harness: harness, initial: initial, next: next)
    }
}

@main struct WorkflowIntegrationChecks {
    @MainActor private static var phase = "startup"
    @MainActor private static var fixtureDirectory: URL?
    @MainActor private static var collectionReopenInspection: [String: Any]?
    @MainActor private static func inspectCollection(_ url: URL) {
        struct Document: Decodable { var version: Int; var runs: [XiaohongshuCollectionRun] }
        do {
            let data = try Data(contentsOf: url)
            let document = try JSONDecoder().decode(Document.self, from: data)
            var invalid: [[String: Any]] = []
            for (index, run) in document.runs.enumerated() {
                do { try run.validate() }
                catch { invalid.append(["index": index, "errorType": String(reflecting: type(of: error)), "error": String(describing: error)]) }
            }
            collectionReopenInspection = ["filename": url.lastPathComponent, "byteCount": data.count,
                "version": document.version, "runCount": document.runs.count, "invalidRuns": invalid]
        } catch {
            collectionReopenInspection = ["filename": url.lastPathComponent, "decodeErrorType": String(reflecting: type(of: error)),
                "decodeError": String(String(describing: error).prefix(1200))]
        }
    }
    @MainActor private static func preserveFailure(_ error: Error) {
        var report: [String: Any] = ["schemaVersion": 1, "phase": phase,
            "errorType": String(reflecting: type(of: error)), "error": String(String(describing: error).prefix(1200)),
            "syntheticFixturesOnly": true]
        if let collectionReopenInspection { report["collectionReopenInspection"] = collectionReopenInspection }
        if let fixtureDirectory {
            report["fixtureDirectory"] = fixtureDirectory.path
            if let enumerator = FileManager.default.enumerator(at: fixtureDirectory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
                var files: [[String: Any]] = []
                while let url = enumerator.nextObject() as? URL, files.count < 500 {
                    if let value = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), value.isRegularFile == true {
                        let rootPath = fixtureDirectory.resolvingSymlinksInPath().path
                        let filePath = url.resolvingSymlinksInPath().path
                        files.append(["path": String(filePath.dropFirst(rootPath.count + 1)), "bytes": value.fileSize ?? -1])
                    }
                }
                report["fixtureFiles"] = files
            }
            if let requested = ProcessInfo.processInfo.environment["WORKFLOW_INTEGRATION_EVIDENCE_DIR"] {
                do {
                    let output = URL(fileURLWithPath: requested, isDirectory: true)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: fixtureDirectory, to: output.appendingPathComponent("fixtures", isDirectory: true))
                    report["preservedFixtures"] = output.appendingPathComponent("fixtures").path
                    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                    try data.write(to: output.appendingPathComponent("failure.json"), options: .atomic)
                } catch { report["preservationError"] = String(String(describing: error).prefix(500)) }
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            FileHandle.standardError.write(data); FileHandle.standardError.write(Data("\n".utf8))
        }
    }
    @MainActor static func main() async throws {
        do { try await run() }
        catch { preserveFailure(error); throw error }
    }
    @MainActor private static func run() async throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func rejects(_ message: String, _ body: () async throws -> Void) async {
            var rejected = false; do { try await body() } catch { rejected = true }; expect(rejected, message)
        }
        func e(_ id: String, _ label: String, _ x: Double, _ y: Double, _ w: Double = 0.2) -> PhoneUIElement {
            .init(id: id, label: label, rect: .init(x: x, y: y, width: w, height: 0.03), source: "ocr")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WorkflowIntegration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fixtureDirectory = directory
        var completed = false
        let keepFixtures = ProcessInfo.processInfo.environment["WORKFLOW_INTEGRATION_KEEP_FIXTURES"] == "1"
        defer { if completed && !keepFixtures { try? FileManager.default.removeItem(at: directory) } }
        let results = [e("brand", "小红书", 0.4, 0.02), e("keyword", "人工智能", 0.25, 0.10),
            e("sort", "排序：综合（已选）", 0.1, 0.20), e("users", "用户", 0.4, 0.20), e("filter", "筛选", 0.8, 0.28, 0.15),
            e("card-a", "标题甲：人工智能笔记", 0.03, 0.40, 0.43), e("card-b", "标题乙：另一笔记", 0.53, 0.40, 0.43)]
        func note(_ id: String, _ body: String) -> [PhoneUIElement] {
            [e("brand", "小红书", 0.4, 0.02), e("back", "返回", 0.03, 0.08, 0.15), e("follow", "关注", 0.8, 0.14, 0.15),
             e("composer", "说点什么", 0.1, 0.90), e("body", "正文：" + body, 0.1, 0.40, 0.8),
             e("source", "https://www.xiaohongshu.com/explore/" + id, 0.01, 0.75, 0.98),
             e("likes", "点赞：12", 0.1, 0.83)]
        }
        let a = "0123456789abcdef01234567", b = "1123456789abcdef01234567"
        let tape = CaptureReplay(folder: directory)
        phase = "collection.first-production-flow"
        let first = tape.show(results)
        tape.queue = [note(a, "人工智能 实测甲"), results, note(b, "人工智能 实测乙")]
        let gui = tape.driver(initial: first)
        let store = XiaohongshuCollectionStore(url: directory.appendingPathComponent("collection.json"))
        ModelProbe.calls = 0
        let collection = try await XiaohongshuCollector(store: store).collect(
            task: .init(id: "bridge-flow-01", keyword: "人工智能", sampleSize: 2),
            driver: LiveXiaohongshuCollectionDriver(gui: gui))
        expect(collection.status == .sampleReached && collection.notes.map(\.id) == [a, b],
            "Production capture -> scoped runtime OCR -> current bound tap -> note source -> store reaches two unique samples")
        expect(tape.executor.actions == [.tap, .tap, .tap] && tape.nextCalls == 3,
            "Live driver opens the current card, returns via an observed Back and opens the next current card")
        expect(tape.recognitions == 4 && ModelProbe.calls == 0, "The complete collection bridge performs local observations without model decisions")
        let firstTap = tape.executor.dispatched[0]
        expect(firstTap.x == results[5].rect.centerX && firstTap.y == results[5].rect.centerY,
            "The dispatched tap uses the exact current OCR rectangle")
        expect(collection.notes[0].source.evidenceElementID.hasPrefix("ocr.") && collection.notes[0].source.evidenceElementID != "source",
            "Source citations retain the production runtime's frame-scoped observation IDs")
        phase = "collection.first-disk-reopen"
        let collectionURL = directory.appendingPathComponent("collection.json")
        let disk = XiaohongshuCollectionStore(url: collectionURL)
        if disk.error != nil { inspectCollection(collectionURL) }
        expect(try disk.run(id: collection.id)?.notes.count == 2, "Integrated production evidence survives disk reload")

        let delegated = CaptureReplay(folder: directory)
        phase = "collection.saved-workflow-delegation"
        let delegatedFrame = delegated.show(results)
        delegated.queue = [note(a, "人工智能 真实生产回放")]
        let delegatedStore = XiaohongshuCollectionStore(url: directory.appendingPathComponent("delegated.json"))
        let savedID = UUID().uuidString
        let savedTask = XiaohongshuCollectionTask(id: savedID, keyword: "人工智能", sampleSize: 1)
        let savedRequest = PhoneHarnessRequest(operation: .xhs_collect, target: savedID, operationID: "saved-bridge-01")
        var delegatedCalls = 0
        delegated.harness.savedWorkflow = { request, frame, next in
            delegatedCalls += 1
            expect(request == savedRequest && frame.capturedAt == delegatedFrame.capturedAt,
                "Runtime delegates the exact validated saved request and captured initial frame")
            let adapter = PhoneWorkflowCaptureDriver(capture: delegated.capture, executor: delegated.executor,
                harness: delegated.harness, initial: frame, next: next)
            let result = try await XiaohongshuCollector(store: delegatedStore).collect(task: savedTask,
                driver: LiveXiaohongshuCollectionDriver(gui: adapter))
            return PhoneHarnessReceipt(summary: String(decoding: try JSONEncoder().encode(result.status), as: UTF8.self),
                verifiedFrame: nil, lastInputCompletedAt: nil)
        }
        let delegatedReceipt = try await delegated.harness.execute(savedRequest, frame: delegatedFrame,
            mappedHome: false, nextFrame: delegated.next)
        expect(delegatedCalls == 1 && delegated.executor.actions == [.tap], "savedWorkflow delegates into the actual production capture/collector flow exactly once")
        let delegatedRun = try delegatedStore.run(id: savedID)
        expect(delegatedRun?.notes.first?.source.noteID == a && delegatedReceipt.summary.contains("sampleReached"),
            "Saved workflow status comes from actual persisted collector evidence")
        expect(delegatedReceipt.verifiedFrame == nil && delegatedReceipt.lastInputCompletedAt == nil,
            "Runtime does not invent terminal-frame or input-timing proof absent from the callback")
        let absent = CaptureReplay(folder: directory), absentFrame = absent.show(results)
        await rejects("A saved request without a configured controller returns an explicit fallback") {
            _ = try await absent.harness.execute(savedRequest, frame: absentFrame, mappedHome: false, nextFrame: absent.next)
        }
        expect(absent.executor.actions.isEmpty && absent.recognitions == 0, "No-handler fallback dispatches no GUI input or model request")
        let pending = CaptureReplay(folder: directory), pendingFrame = pending.show(results)
        var bypassCalls = 0
        pending.harness.externalPendingReview = { true }
        pending.harness.savedWorkflow = { _, _, _ in bypassCalls += 1; throw AgentError.message("must not be invoked") }
        await rejects("External pending file/workflow review blocks saved-workflow delegation") {
            _ = try await pending.harness.execute(savedRequest, frame: pendingFrame, mappedHome: false, nextFrame: pending.next)
        }
        await rejects("External pending review also blocks generic taps from bypassing that receipt") {
            _ = try await pending.harness.execute(.init(operation: .tap, target: "card-a"), frame: pendingFrame,
                mappedHome: false, nextFrame: pending.next)
        }
        expect(bypassCalls == 0 && pending.executor.actions.isEmpty, "Pending review cannot be bypassed through either saved or generic GUI paths")
        var readOnlyCalls = 0
        pending.harness.savedWorkflow = { request,_,_ in
            guard request.operation == .file_status else {throw AgentError.message("unexpected input")}
            readOnlyCalls += 1
            return .init(summary:"pending record",verifiedFrame:nil,lastInputCompletedAt:nil,requiresUserReview:true)
        }
        let pendingStatus = try await pending.harness.execute(.init(operation:.file_status,target:savedID,operationID:"read-status-1"),frame:pendingFrame,mappedHome:false,nextFrame:pending.next)
        expect(readOnlyCalls == 1 && pendingStatus.requiresUserReview && pending.executor.actions.isEmpty,"Pending journals remain readable without enabling any GUI input")
        let failed = CaptureReplay(folder: directory), failedFrame = failed.show(results)
        failed.harness.savedWorkflow = { _, _, _ in throw AgentError.message("actual workflow failed before completion") }
        await rejects("Callback failure propagates as failure rather than a synthetic successful receipt") {
            _ = try await failed.harness.execute(savedRequest, frame: failedFrame, mappedHome: false, nextFrame: failed.next)
        }

        let fresh = CaptureReplay(folder: directory)
        phase = "capture.current-frame-preconditions"
        let old = fresh.show(results)
        let freshGUI = PhoneWorkflowCaptureDriver(capture: fresh.capture, executor: fresh.executor, harness: fresh.harness,
            initial: old, next: { _ in old })
        let (_, initialSnapshot) = try await freshGUI.read()
        expect(initialSnapshot.scene == "xiaohongshu.results", "Initial actual frame is classified by the production adapter")
        await rejects("Repeated callback frame is not accepted as a fresh observation") { _ = try await freshGUI.read() }
        expect(fresh.recognitions == 1, "Repeated-frame failure happens before another OCR or GUI input")

        let exact = CaptureReplay(folder: directory)
        let exactFrame = exact.show(results), exactGUI = exact.driver(initial: nil)
        _ = exactFrame
        let (_, exactSnapshot) = try await exactGUI.read()
        let candidate = exactSnapshot.elements.first { $0.label == "标题甲：人工智能笔记" }!
        var changed = candidate; changed.rect.y += 0.05
        await rejects("An old ID with modified bounds cannot dispatch a guessed location") { try await exactGUI.tap(changed) }
        var generated = candidate; generated.source = "model"
        await rejects("A model-created element cannot enter the observed-input bridge") { try await exactGUI.tap(generated) }
        _ = exact.show(results.filter { $0.id != "card-a" } + [e("other", "其他内容占原位置", 0.03, 0.40, 0.43)])
        await rejects("A newer pixel frame prevents tapping an element from old OCR") { try await exactGUI.tap(candidate) }
        expect(exact.executor.actions.isEmpty, "All stale/changed-target failures occur before dispatch")

        for kind in ["accessory", "stream", "size", "source-size", "not-full", "stopped", "unready"] {
            let switched = CaptureReplay(folder: directory)
            let origin = switched.show(results)
            let switchedGUI = switched.driver(initial: origin)
            _ = try await switchedGUI.read()
            switch kind {
            case "accessory": switched.executor.ble.selectedID = "different-accessory"
            case "stream": _ = switched.show(results, stream: UUID())
            case "size": var frame = switched.show(results); frame.width += 1; switched.capture.frozenFrame = frame
            case "source-size": var frame = switched.show(results); frame.sourceHeight += 1; switched.capture.frozenFrame = frame
            case "not-full": var frame = switched.show(results); frame.fullDisplay = false; switched.capture.frozenFrame = frame
            case "stopped": switched.capture.running = false
            default: switched.executor.ble.ready = false
            }
            let oldTarget = try await switched.harness.workflowSnapshot(origin).elements.first { $0.label == "标题甲：人工智能笔记" }!
            await rejects("Changed capture/accessory preconditions prohibit current action: " + kind) { try await switchedGUI.tap(oldTarget) }
            expect(switched.executor.actions.isEmpty, "No input dispatched after precondition changed: " + kind)
        }

        let during = CaptureReplay(folder: directory), duringFrame = during.show(results)
        phase = "capture.await-cancellation-and-overlay"
        during.onRecognize = { _ = during.show(results, stream: UUID()) }
        await rejects("Screen sharing changed during awaited OCR invalidates the original frame") {
            _ = try await during.driver(initial: duringFrame).read()
        }
        expect(during.executor.actions.isEmpty, "A sharing switch during OCR never results in input")
        let duringAccessory = CaptureReplay(folder: directory), accessoryFrame = duringAccessory.show(results)
        duringAccessory.onRecognize = { duringAccessory.executor.ble.selectedID = "new-device" }
        await rejects("Accessory switching during OCR is checked after the await") {
            _ = try await duringAccessory.driver(initial: accessoryFrame).read()
        }

        let overlay = CaptureReplay(folder: directory)
        let blocked = overlay.show(results + [e("alert", "允许", 0.4, 0.5)])
        await rejects("A blocking overlay recognized by the production harness stops collection") { _ = try await overlay.driver(initial: blocked).read() }
        expect(overlay.executor.actions.isEmpty, "Overlay failure produces no clicks")
        let stale = CaptureReplay(folder: directory)
        let staleFrame = stale.show(results, at: Date().addingTimeInterval(-2))
        await rejects("Old frames cannot start a workflow") { _ = try await stale.driver(initial: staleFrame).read() }
        expect(stale.recognitions == 0, "Freshness is checked before expensive OCR")
        let calibration = CaptureReplay(folder: directory)
        _ = calibration.show(results)
        let calibrationGUI = calibration.driver()
        let (_, calibrationSnapshot) = try await calibrationGUI.read()
        calibration.executor.calibrationValid = false
        await rejects("Invalid pointer calibration blocks observed target input") { try await calibrationGUI.tap(calibrationSnapshot.elements[5]) }
        expect(calibration.executor.actions.isEmpty, "Calibration failure dispatches no GUI action")

        let cancelled = CaptureReplay(folder: directory), cancelFrame = cancelled.show(results)
        let cancellation = Task { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await cancelled.driver(initial: cancelFrame).read()
        }
        do { try await cancellation.value; preconditionFailure("Cancellation was ignored") } catch is CancellationError { checks += 1 }
        expect(cancelled.recognitions == 0 && cancelled.executor.actions.isEmpty, "Cancellation stops before OCR or input")
        let cancelledDuring = CaptureReplay(folder: directory), cancelDuringFrame = cancelledDuring.show(results)
        var duringTask: Task<Void, Error>?
        cancelledDuring.onRecognize = { duringTask?.cancel() }
        duringTask = Task { _ = try await cancelledDuring.driver(initial: cancelDuringFrame).read() }
        do { try await duringTask!.value; preconditionFailure("Cancellation during OCR was ignored") } catch is CancellationError { checks += 1 }
        expect(cancelledDuring.executor.actions.isEmpty, "Cancellation during OCR prevents later GUI input")

        let missingBack = CaptureReplay(folder: directory)
        let noBackFrame = missingBack.show(note(a, "人工智能").filter { $0.id != "back" })
        let noBackGUI = missingBack.driver(initial: noBackFrame)
        _ = try await noBackGUI.read()
        await rejects("Missing Back control cannot fall back to an invented coordinate") { try await noBackGUI.returnToResults() }
        expect(missingBack.executor.actions.isEmpty, "Missing navigation anchor leaves persisted data without further input")

        // The real runtime keeps the generic cached observation blocked. Only
        // the domain controller receives a narrowly permitted menu copy.
        let shareMenu = [e("share-heading", "分享至", 0.1, 0.52, 0.8),
            e("copy-link", "复制链接", 0.1, 0.69, 0.4), e("share-cancel", "取消", 0.35, 0.9, 0.3)]
        let domain = CaptureReplay(folder: directory), menuFrame = domain.show(shareMenu)
        phase = "capture.domain-menu-policy"
        let menuGUI = domain.driver(initial: menuFrame)
        menuGUI.menuPolicy = { XiaohongshuPageAdapter.identity(in: $0)?.scene == "xiaohongshu.share" }
        let (_, allowedMenu) = try await menuGUI.read()
        expect(!allowedMenu.blockingOverlay && allowedMenu.scene == "xiaohongshu.share",
            "A real Share/Copy link/Cancel combination is readable under the XHS domain menu policy")
        let genericObject = try JSONSerialization.jsonObject(with: Data((try await domain.harness.context(for: menuFrame)).utf8)) as! [String: Any]
        expect(genericObject["blocked"] as? Bool == true,
            "Reading an allowed domain-menu copy does not unblock the same frame in the generic harness cache")
        let copyTarget = allowedMenu.elements.first { $0.label == "复制链接" }!
        await rejects("Generic phone_tool cannot bypass a blocked share menu after a domain read") {
            _ = try await domain.harness.execute(.init(operation: .tap, target: copyTarget.id), frame: menuFrame,
                mappedHome: false, nextFrame: domain.next)
        }
        expect(domain.executor.actions.isEmpty, "Generic menu rejection occurs before GUI input")
        try await menuGUI.tap(copyTarget)
        expect(domain.executor.actions == [.tap] && domain.executor.dispatched[0].x == copyTarget.rect.centerX,
            "The domain controller can dispatch only the actual currently observed Copy control")
        let deniedMenu = CaptureReplay(folder: directory), deniedMenuFrame = deniedMenu.show(shareMenu)
        await rejects("The same menu remains blocked without an explicit domain policy") {
            _ = try await deniedMenu.driver(initial: deniedMenuFrame).read()
        }
        let unknownMenu = CaptureReplay(folder: directory)
        let unknownMenuFrame = unknownMenu.show(shareMenu.filter { $0.id != "share-heading" })
        let unknownMenuGUI = unknownMenu.driver(initial: unknownMenuFrame)
        unknownMenuGUI.menuPolicy = { XiaohongshuPageAdapter.identity(in: $0)?.scene == "xiaohongshu.share" }
        await rejects("Copy and Cancel without the trusted share-panel anchors remain blocked") { _ = try await unknownMenuGUI.read() }
        for label in ["允许", "Allow", "确认付款", "确定", "OK"] {
            let hard = CaptureReplay(folder: directory)
            let hardFrame = hard.show(shareMenu + [e("system-hard", label, 0.4, 0.42, 0.3)])
            let hardGUI = hard.driver(initial: hardFrame)
            var policyCalls = 0
            hardGUI.menuPolicy = { _ in policyCalls += 1; return true }
            await rejects("Hard permission/payment/confirmation cannot be overridden even by a permissive menu policy: " + label) {
                _ = try await hardGUI.read()
            }
            expect(policyCalls == 0 && hard.executor.actions.isEmpty,
                "The hard-blocker check runs before any menu policy or GUI dispatch: " + label)
        }

        func visual(_ id: String, _ label: String, _ x: Double = 0.03, _ y: Double = 0.05) -> PhoneUIElement {
            var value = e(id, label, x, y, 0.1); value.source = "local_visual"; return value
        }
        let visualTape = CaptureReplay(folder: directory)
        phase = "capture.visual-controls"
        let visualElements = note(a, "当前图形控件").filter { $0.id != "back" } + [visual("native-more", "视觉:更多", 0.85, 0.03)]
        let visualFrame = visualTape.show(visualElements), visualGUI = visualTape.driver(initial: nil)
        _ = visualFrame
        let (_, visualSnapshot) = try await visualGUI.read()
        let observedVisual = visualSnapshot.elements.first { $0.label == "视觉:更多" }!
        expect(observedVisual.source == "local_visual" && observedVisual.id.hasPrefix("local_visual."),
            "The production runtime namespaces native image-derived controls to this exact observed frame")
        var forgedVisual = observedVisual; forgedVisual.source = "model"
        await rejects("Changing the source of a real local-visual element cannot forge dispatch authority") { try await visualGUI.tap(forgedVisual) }
        var unknownVisual = observedVisual; unknownVisual.id = "local_visual.invented"; unknownVisual.rect.y += 0.1
        await rejects("An invented local-visual ID/rectangle cannot enter the current observation") { try await visualGUI.tap(unknownVisual) }
        try await visualGUI.tap(observedVisual)
        expect(visualTape.executor.actions == [.tap] && visualTape.executor.dispatched[0].y == observedVisual.rect.centerY,
            "An exact current local-visual element dispatches its observed bounds")
        _ = visualTape.show(visualElements)
        let (_, rereadVisual) = try await visualGUI.read()
        expect(rereadVisual.elements.first { $0.label == "视觉:更多" }?.id != observedVisual.id,
            "A later pixel observation gets a different native-control identity even at the same point")
        await rejects("A same-location native control from an expired frame ID cannot be tapped") { try await visualGUI.tap(observedVisual) }
        expect(visualTape.executor.actions.count == 1, "Neither forged nor stale visual targets add a GUI dispatch")
        for label in ["视觉:返回", "视觉:关闭"] {
            let navigation = CaptureReplay(folder: directory)
            let frame = navigation.show(note(a, "图形返回笔记").filter { $0.id != "back" } + [visual("actual-navigation", label)])
            let navigationGUI = navigation.driver(initial: frame)
            let (_, snapshot) = try await navigationGUI.read()
            let target = snapshot.elements.first { $0.label == label }!
            try await navigationGUI.returnToResults()
            expect(navigation.executor.actions == [.tap] && navigation.executor.dispatched[0].x == target.rect.centerX && navigation.executor.dispatched[0].y == target.rect.centerY,
                "XHS return uses the unique actual top-left local-visual navigation control: " + label)
        }
        for failure in ["ambiguous", "wrong-roi", "wrong-page", "ambiguous-ocr"] {
            let navigation = CaptureReplay(folder: directory)
            var elements = note(a, "不能猜返回").filter { $0.id != "back" }
            switch failure {
            case "ambiguous": elements += [visual("back-a", "视觉:返回"), visual("close-b", "视觉:关闭", 0.15, 0.05)]
            case "wrong-roi": elements += [visual("wrong-side", "视觉:返回", 0.85, 0.05)]
            case "wrong-page": elements = results + [visual("back", "视觉:返回")]
            default: elements += [e("back-a", "返回", 0.02, 0.05, 0.1), e("back-b", "返回", 0.14, 0.05, 0.1), visual("native", "视觉:返回")]
            }
            let frame = navigation.show(elements), navigationGUI = navigation.driver(initial: nil)
            _ = frame; _ = try await navigationGUI.read()
            await rejects("XHS return rejects ambiguous, misplaced or wrong-page controls: " + failure) { try await navigationGUI.returnToResults() }
            expect(navigation.executor.actions.isEmpty, "Unknown return state never falls back to guessed coordinates: " + failure)
        }
        let diagnosticTape=CaptureReplay(folder:directory)
        phase = "capture.actual-diagnostics-store"
        let diagnosticFrame=diagnosticTape.show(results)
        let diagnosticStore=WorkflowDiagnosticsStore(directory:directory.appendingPathComponent("actual-driver-diagnostics"))
        let diagnosticGUI=PhoneWorkflowCaptureDriver(capture:diagnosticTape.capture,executor:diagnosticTape.executor,harness:diagnosticTape.harness,initial:diagnosticFrame,next:diagnosticTape.next,diagnostics:diagnosticStore)
        diagnosticGUI.diagnosticWorkflowID="fixture-workflow"
        let (_,diagnosticSnapshot)=try await diagnosticGUI.read()
        let originalRecord=diagnosticStore.records.first!
        expect(originalRecord.imageStored && originalRecord.context.snapshot == diagnosticSnapshot,"Production capture driver archives actual JPEG and exact runtime OCR")
        expect(try diagnosticStore.preview(id:originalRecord.id) == diagnosticFrame.jpeg,"Stored screenshot is original fixture JPEG, not a recreated image/hash")
        let diagnosticTarget=diagnosticSnapshot.elements.first {$0.label == "标题甲：人工智能笔记"}!
        try await diagnosticGUI.tap(diagnosticTarget)
        expect(diagnosticStore.records.map(\.context.boundary) == [.observed,.beforeInput,.afterInput],"Observed, before-input and returned-input boundaries are ordered")
        expect(diagnosticStore.records.last?.context.result?.contains("等待后续真实画面核验") == true,"Input return does not become a verified result screenshot")
        _ = diagnosticTape.show(results)
        await rejects("Stale diagnostic target still cannot dispatch") {try await diagnosticGUI.tap(diagnosticTarget)}
        expect(diagnosticStore.records.last?.context.boundary == .failed && diagnosticTape.executor.actions.count==1,"Stale-target failure is archived without replaying input")
        diagnosticGUI.diagnosticOperationID="pending-fixture-operation"
        diagnosticGUI.protectSubmissionEvidence=true
        diagnosticGUI.recordOutcome(.pendingSubmission,reason:"synthetic pending boundary")
        expect(diagnosticStore.records.last?.isProtectedPendingSubmission == true,"Potential submission protects its original screenshot")
        let modelBeforeDiagnostics=ModelProbe.calls
        let diagnosticExport=try diagnosticStore.export()
        let exportedBundle=try JSONDecoder().decode(WorkflowDiagnosticsBundle.self,from:Data(contentsOf:diagnosticExport.url))
        expect(exportedBundle.entries.contains {$0.jpeg == diagnosticFrame.jpeg},"One shareable diagnostic package includes actual original screenshot bytes")
        let cleaned=try diagnosticStore.clearResolved()
        expect(cleaned.retainedProtectedRecords==1 && diagnosticStore.records.count==1,"Ordinary cleanup retains unresolved submission evidence")
        expect(ModelProbe.calls == modelBeforeDiagnostics && diagnosticTape.executor.actions.count==1,"Diagnostic export and cleanup dispatch no model or phone operation")
        let absentEvidenceTape=CaptureReplay(folder:directory)
        let expiredEvidence=absentEvidenceTape.show(results,at:Date().addingTimeInterval(-3))
        let absentEvidenceGUI=PhoneWorkflowCaptureDriver(capture:absentEvidenceTape.capture,executor:absentEvidenceTape.executor,harness:absentEvidenceTape.harness,initial:expiredEvidence,diagnostics:diagnosticStore)
        await rejects("A stale initial frame cannot manufacture a diagnostic screenshot") {_ = try await absentEvidenceGUI.read()}
        expect(absentEvidenceGUI.diagnosticRecordingError != nil && diagnosticStore.records.count==1,"No valid observation reports missing evidence and retains existing protected records")
        let clockTape = CaptureReplay(folder: directory)
        phase = "capture.real-clock-fixtures"
        let beforeDefaultShow = Date()
        let firstClockFrame = clockTape.show(results)
        let distinctElements = note(a, "独立时钟交付证据")
        let secondClockFrame = clockTape.show(distinctElements)
        expect(firstClockFrame.capturedAt > beforeDefaultShow && secondClockFrame.capturedAt > firstClockFrame.capturedAt,
            "Default synthetic frame deliveries wait for actual strictly increasing clock values")
        expect(clockTape.observations[firstClockFrame.capturedAt] == results && clockTape.observations[secondClockFrame.capturedAt] == distinctElements,
            "Consecutive deliveries retain distinct source timestamps and do not overwrite another frame's OCR")
        clockTape.queue = [results]
        let actualInputBoundary = Date()
        let nextClockFrame = try clockTape.next(actualInputBoundary)
        expect(nextClockFrame.capturedAt > actualInputBoundary && nextClockFrame.confirmedAt > actualInputBoundary &&
               clockTape.observations[nextClockFrame.capturedAt] == results && clockTape.queue.isEmpty && clockTape.nextCalls == 1,
            "Queued delivery crosses the actual boundary before consuming exactly the corresponding source page")
        let explicitOldTime = Date().addingTimeInterval(-3)
        let explicitOldFrame = clockTape.show(results, at: explicitOldTime)
        expect(explicitOldFrame.capturedAt == explicitOldTime && explicitOldFrame.confirmedAt == explicitOldTime,
            "Explicit old-frame fixtures retain the exact old pixel and confirmation timestamps")

        // A native viewDidAppear boundary is newer than this adapter's last
        // observation even without GUI input. It must reach the real wait, not
        // be checked only after an older-but-fresh current frame was returned.
        let equalBoundaryTape = CaptureReplay(folder: directory)
        let equalBoundaryFrame = equalBoundaryTape.show(results)
        equalBoundaryTape.queue = [results]
        let equalBoundaryGUI = equalBoundaryTape.driver(initial: equalBoundaryFrame)
        let (afterEqual, _) = try await equalBoundaryGUI.read(after: equalBoundaryFrame.confirmedAt)
        expect(afterEqual.confirmedAt > equalBoundaryFrame.confirmedAt && equalBoundaryTape.nextCalls == 1,
            "An initial frame exactly equal to an external watermark is skipped and the watermark reaches next(after:)")
        expect(equalBoundaryTape.recognitions == 1,
            "A frame at the native boundary is rejected before OCR rather than retimed or reused")

        let nativeOriginal = directory.appendingPathComponent("send-after-boundary.txt")
        try Data("PHONE AGENT ACCEPTANCE\nFixture A\n".utf8).write(to: nativeOriginal)
        for mode in ["new-frame", "no-frame", "cancel-wait", "changed-stream", "changed-accessory"] {
            phase = "native-presentation." + mode
            let nativeTape = CaptureReplay(folder: directory)
            let prePresentationFrame = nativeTape.show(results)
            let nativeGUI = PhoneWorkflowCaptureDriver(capture: nativeTape.capture, executor: nativeTape.executor,
                harness: nativeTape.harness, initial: prePresentationFrame)
            let (_, beforeNative) = try await nativeGUI.read()
            let originalStore = FileTransferStore(url: directory.appendingPathComponent(mode + "/file-checkpoints.json"))
            let original = try await originalStore.importFileAsync(at: nativeOriginal, sourceID: "explicit-original", mediaType: "public.plain-text")
            let target = FileTransferRecipient.selfTransfer(artifactIDs: [original.id])
            let environment = FileTransferEnvironment(deviceKey: beforeNative.deviceKey, accessoryKey: nativeTape.executor.ble.selectedID!,
                captureSessionID: nativeTape.stream.uuidString, foreground: true)
            let confirm = [e("heading", "发送给", 0.4, 0.06), e("target", "文件传输助手", 0.3, 0.14, 0.4),
                e("explanation", "你可以在手机和电脑间互传文件", 0.1, 0.21, 0.8), e("count", "1 个文件", 0.6, 0.28),
                e("file", original.filename, 0.2, 0.38, 0.6), e("size", "33 字节", 0.3, 0.42),
                e("original", "已选择原文件", 0.3, 0.70, 0.4), e("send", "发送", 0.75, 0.84)]
            nativeTape.queue = [confirm, confirm]
            let gate = FrameReadinessGate()
            var waits: [Date] = [], reads: [Date] = []
            var nativeID: UUID?, presentedAt: Date?, presentations = 0
            nativeTape.capture.waitHandler = { after, timeout in
                waits.append(after)
                if mode == "cancel-wait" { withUnsafeCurrentTask { $0?.cancel() } }
                else if mode == "changed-stream" { _ = nativeTape.show(confirm, stream: UUID()) }
                else if mode == "changed-accessory" {
                    nativeTape.executor.ble.selectedID = "different-accessory"
                    _ = try nativeTape.next(after)
                } else if mode == "new-frame" { _ = try nativeTape.next(after) }
                gate.update(confirmedAt: nativeTape.capture.frame?.confirmedAt, available: nativeTape.capture.running)
                return try await gate.wait(after: after, timeout: timeout)
            }
            let nativeDriver = WeChatFileTransferDriver(read: { after in
                reads.append(after)
                let (frame, snapshot) = try await nativeGUI.read(after: after)
                return .init(snapshot: snapshot, captureSessionID: frame.captureID!, frameID: UUID().uuidString, confirmedAt: frame.confirmedAt)
            }, tap: { try await nativeGUI.tap($0) }, scroll: { try await nativeGUI.scroll(older: $0) }, present: { payload in
                presentations += 1
                let disk = FileTransferStore(url: originalStore.url)
                expect(disk.hasPendingReview && disk.operations[0].lastSelection == nil,
                    "The production ledger is pending before the synthetic native host can present: " + mode)
                expect(payload.fileURLs.count == 1 && (try? Data(contentsOf: payload.fileURLs[0])) == (try? Data(contentsOf: nativeOriginal)),
                    "The presented controller receives actual original bytes: " + mode)
                let id = UUID(); nativeID = id
                let binding = WeChatNativeShareBinding(presentationID: id, payload: payload)
                presentedAt = binding.presentedAt
                return binding
            }, isPresented: { nativeID == $0 })
            let coordinator = FileTransferCoordinator(store: originalStore)
            presentations = 0
            // Counting the actual host is separate from dispatch count.
            let operation: FileTransferOperation
            do {
                let attempt = Task { try await coordinator.beginAutomaticNativeShare(operationID: "watermark-" + mode, taskID: mode,
                    recipient: target, artifactIDs: [original.id], environment: environment, automaticDriver: nativeDriver) }
                operation = try await attempt.value
            } catch is CancellationError {
                expect(mode == "cancel-wait", "Only the deliberately cancelled capture wait propagates cancellation")
                operation = originalStore.operations[0]
            }
            expect(presentations == 1 && reads.first == presentedAt && waits.first == presentedAt && presentedAt! > prePresentationFrame.confirmedAt,
                "Native presentation's actual timestamp crosses the production driver and reaches FrameReadinessGate: " + mode)
            if mode == "new-frame" {
                expect(nativeTape.executor.actions == [.tap] && operation.lastSelection != nil && reads.count == 2 && waits.count == 2,
                    "A later actual callback enables one Send and a separate read-only post-dispatch wait")
                expect(operation.lastSelection?.context.confirmedAt.map { $0 > presentedAt! } == true,
                    "The stored selection proof truly follows native presentation without changing old frame time")
            } else {
                expect(nativeTape.executor.actions.isEmpty && operation.lastSelection == nil,
                    "Missing, cancelled or changed capture evidence never taps Send: " + mode)
                expect(nativeTape.nextCalls <= 1,
                    "A rejected capture does not replay source pages or inputs: " + mode)
            }
            expect(operation.pending && FileTransferStore(url: originalStore.url).hasPendingReview,
                "Every post-presentation outcome remains durable pending rather than guessed not-submitted: " + mode)
            if ["no-frame", "changed-stream", "changed-accessory"].contains(mode) {
                let marker = operation.detail.range(of: "captureFailure=")!
                let compact = Data(operation.detail[marker.upperBound...].utf8)
                let object = try JSONSerialization.jsonObject(with: compact) as! [String: Any]
                expect(object["schemaVersion"] as? Int == 1 && !(object["failedPredicateCodes"] as! [String]).isEmpty,
                    "The unchanged durable unknown receipt preserves complete compact capture predicates within its existing error limit: " + mode)
            }
            let unchanged = try await coordinator.beginAutomaticNativeShare(operationID: "watermark-" + mode, taskID: mode,
                recipient: target, artifactIDs: [original.id], environment: environment, automaticDriver: nativeDriver)
            expect(unchanged.pending && presentations == 1 && reads.count == (mode == "new-frame" ? 2 : 1),
                "Repeating a pending operation performs no additional presentation, read or Send: " + mode)
            nativeTape.capture.waitHandler = nil
        }
        phase = "capture.structured-predicates-and-lifecycle"
        checks += try await CaptureFailureChecks.run(folder: directory, elements: results)
        checks += try await ScrollBindingChecks.run(folder: directory, elements: results)
        completed = true
        if keepFixtures { print("WorkflowIntegration synthetic fixture directory: " + directory.path) }
        print("Workflow capture/collector integration checks passed: \(checks). Synthetic frame/OCR/input only; no device, real OCR, Bluetooth, network or API acceptance.")
    }
}
