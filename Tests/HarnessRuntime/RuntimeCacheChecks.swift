import Foundation
import CoreGraphics

@MainActor private final class RuntimeCacheGate {
    private var pending: [CheckedContinuation<Void, Never>] = []
    var count: Int { pending.count }
    func wait() async { await withCheckedContinuation { pending.append($0) } }
    func releaseAll() { let values = pending; pending = []; values.forEach { $0.resume() } }
}

@MainActor enum HarnessRuntimeCacheChecks {
    static func run(directory: URL, reportURL: URL? = nil) async throws -> Int {
        var checks = 0, cases: [[String: Any]] = []
        func record(_ name: String, _ values: [String: Any]) throws {
            var entry = values; entry["case"] = name; cases.append(entry)
            if let reportURL {
                let data = try JSONSerialization.data(withJSONObject: ["offlineInjectedOnly": true, "cases": cases], options: [.prettyPrinted, .sortedKeys])
                try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: reportURL, options: .atomic)
            }
        }
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func waitForGate(_ gate: RuntimeCacheGate, count: Int, name: String) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while gate.count < count {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    try record("gate timeout", ["name": name, "expectedWaiters": count, "actualWaiters": gate.count])
                    throw AgentError.message("离线测试未到达受控识别阶段：" + name)
                }
                await Task.yield()
            }
        }
        func element(_ id: String, _ label: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> PhoneUIElement {
            .init(id: id, label: label, rect: .init(x: x, y: y, width: width, height: height), source: "ocr")
        }
        let candidate = [element("account", "Weixin ID: filehelper", 0.214, 0.170, 0.347, 0.016),
            element("about1", "Transfer text, images, audio and video files", 0.217, 0.263, 0.738, 0.020),
            element("about2", "between your device and your PC", 0.217, 0.283, 0.581, 0.020),
            element("messages", "• Messages", 0.378, 0.347, 0.247, 0.021)]
        let title = element("actual-fixture-title", "文件传输助手", 0.2135, 0.1338, 0.29, 0.0231)
        func frame(capture: UUID? = UUID(), pixelTime: Date = Date().addingTimeInterval(-5)) -> ScreenFrame {
            ScreenFrame(capturedAt: pixelTime, captureID: capture).confirmed(at: Date())
        }
        func isTitle(_ snapshot: PhoneUISnapshot) -> Bool { snapshot.elements.contains { $0.label == title.label } }
        let modelBefore = ModelProbe.calls

        var fullCalls = 0, roiCalls = 0
        let executor = MouseExecutor()
        let runtime = PhoneHarnessRuntime(executor: executor, memoryURL: directory.appendingPathComponent("roi-memo.json"), recognize: { _ in
            fullCalls += 1; return candidate
        }, recognizeWorkflowTitle: { _ in roiCalls += 1; return [title] })
        let source = frame(), started = ProcessInfo.processInfo.systemUptime
        var outputs: [PhoneUISnapshot] = []
        for _ in 0..<25 { outputs.append(try await runtime.workflowSnapshot(source.confirmed(at: Date()))) }
        let duration = ProcessInfo.processInfo.systemUptime - started
        try record("25 sequential same pixels with real explicit idle callbacks", ["reads": 25, "fullCalls": fullCalls, "roiCalls": roiCalls, "elapsedSeconds": duration])
        expect(fullCalls == 1 && roiCalls == 1, "Twenty-five sequential reads reuse one pixel-scoped full OCR and one raw ROI result")
        expect(outputs.allSatisfy(isTitle) && outputs.allSatisfy { $0.capturedAt == source.capturedAt }, "Cached title results preserve source pixel time and actual labels")
        expect(outputs.map { $0.elements.first { $0.label == title.label }!.id }.allSatisfy { $0 == outputs[0].elements.first { $0.label == title.label }!.id }, "Same-pixel ROI anchors retain their original capture-bound ID")
        let context = try await runtime.context(for: source.confirmed(at: Date()))
        expect(!context.contains(title.label) && fullCalls == 1 && roiCalls == 1, "Domain-only ROI cache never injects title elements into generic context")
        var staleRejected = false
        do { _ = try await runtime.workflowSnapshot(source.confirmed(at: Date().addingTimeInterval(-2))) } catch { staleRejected = true }
        expect(staleRejected && fullCalls == 1 && roiCalls == 1, "A memo hit cannot bypass the caller's stale confirmation guard")
        let cancelledHit = Task { try await runtime.workflowSnapshot(source.confirmed(at: Date())) }
        cancelledHit.cancel()
        var cancelledHitRejected = false
        do { _ = try await cancelledHit.value } catch is CancellationError { cancelledHitRejected = true }
        expect(cancelledHitRejected && roiCalls == 1, "A cancelled cache-hit caller receives no OCR result")

        let beforeVariants = fullCalls
        var variants: [ScreenFrame] = []
        var resized = source; resized.width = 4; variants.append(resized)
        resized = source; resized.height = 4; variants.append(resized)
        resized = source; resized.sourceWidth = 4; variants.append(resized)
        resized = source; resized.sourceHeight = 4; variants.append(resized)
        func image(width: Int, height: Int) -> UIImage {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return UIImage(cgImage: context.makeImage()!)
        }
        resized = source; resized.image = image(width: 4, height: 2); variants.append(resized)
        resized = source; resized.image = image(width: 2, height: 4); variants.append(resized)
        for (index, variant) in variants.enumerated() {
            let beforeFull = fullCalls, beforeROI = roiCalls
            _ = try await runtime.workflowSnapshot(variant.confirmed(at: Date()))
            expect(fullCalls == beforeFull + 1 && roiCalls == beforeROI + 1, "Every independent logical/source/CG geometry change invalidates both pixel caches: \(index)")
        }
        try record("geometry isolation", ["variants": variants.count, "fullCallsAdded": fullCalls - beforeVariants, "roiCalls": roiCalls])
        let geometryBefore = fullCalls
        _ = try await runtime.workflowSnapshot(source.confirmed(at: Date()))
        expect(fullCalls == geometryBefore + 1, "The raw ROI memo contains only one geometry entry; returning to an evicted entry re-recognizes")
        var newPixel = frame(capture: source.captureID, pixelTime: Date())
        let pixelBefore = fullCalls
        _ = try await runtime.workflowSnapshot(newPixel)
        expect(fullCalls == pixelBefore + 1, "A real newer pixel timestamp invalidates both caches")
        let captureBefore = fullCalls
        newPixel = frame(capture: UUID(), pixelTime: source.capturedAt)
        _ = try await runtime.workflowSnapshot(newPixel)
        expect(fullCalls == captureBefore + 1, "A replacement capture UUID cannot inherit the same timestamp's cached OCR")
        let accessoryBefore = fullCalls
        executor.ble.selectedID = "new-selected-device"
        let onNewAccessory = try await runtime.workflowSnapshot(newPixel.confirmed(at: Date()))
        expect(fullCalls == accessoryBefore + 1 && onNewAccessory.deviceKey.contains("new-selected-device"), "A new selected accessory receives separately observed text and a correctly bound device key")
        let resetBefore = fullCalls
        runtime.reset(); _ = try await runtime.workflowSnapshot(newPixel.confirmed(at: Date()))
        expect(fullCalls == resetBefore + 1, "Reset invalidates completed full and ROI memo entries")
        let nilBefore = fullCalls, nilROIBefore = roiCalls
        let anonymous = frame(capture: nil, pixelTime: newPixel.capturedAt)
        _ = try await runtime.workflowSnapshot(anonymous)
        _ = try await runtime.workflowSnapshot(anonymous.confirmed(at: Date()))
        _ = try await runtime.workflowSnapshot(newPixel.confirmed(at: Date()))
        try record("nil capture isolation", ["reads": 3, "fullCallsAdded": fullCalls - nilBefore, "roiCallsAdded": roiCalls - nilROIBefore])
        expect(fullCalls == nilBefore + 3 && roiCalls == nilROIBefore + 3, "Anonymous captures neither cache results nor preserve a previous named entry for reverse reuse")
        var partialDisplay = source; partialDisplay.fullDisplay = false
        var partialRejected = false
        do { _ = try await runtime.workflowSnapshot(partialDisplay.confirmed(at: Date())) } catch { partialRejected = true }
        expect(partialRejected, "A memo never turns an app-only capture into a full-display observation")

        // The controls are continuations, not guessed scheduler sleeps. They
        // change the relevant state while the production async seam is paused.
        for stage in ["full", "roi"] {
            for fault in ["selected-device", "reset", "cancel"] {
                let gate = RuntimeCacheGate(), owner = MouseExecutor()
                var full = 0, roi = 0
                let tested = PhoneHarnessRuntime(executor: owner, memoryURL: directory.appendingPathComponent("\(stage)-\(fault).json"), recognize: { _ in
                    full += 1
                    if stage == "full" && full == 1 { await gate.wait() }
                    return candidate
                }, recognizeWorkflowTitle: { _ in
                    roi += 1
                    if stage == "roi" && roi == 1 { await gate.wait() }
                    return [title]
                })
                let input = frame()
                let attempt = Task { try await tested.workflowSnapshot(input) }
                try await waitForGate(gate, count: 1, name: "\(stage)-\(fault)")
                if fault == "selected-device" { owner.ble.selectedID = "replacement-while-awaiting" }
                if fault == "reset" { tested.reset() }
                if fault == "cancel" { attempt.cancel() }
                gate.releaseAll()
                var rejected = false, wasCancellation = false
                do { _ = try await attempt.value }
                catch { rejected = true; wasCancellation = error is CancellationError }
                let after = try await tested.workflowSnapshot(input.confirmed(at: Date()))
                try record("\(stage) await \(fault)", ["rejected": rejected, "cancellationError": wasCancellation, "fullCallsAfterRetry": full, "roiCallsAfterRetry": roi, "inputCalls": owner.actions.count])
                expect(rejected && (fault != "cancel" || wasCancellation), "An async \(stage) result is rejected after \(fault)")
                expect(full == (stage == "roi" && fault == "cancel" ? 1 : 2) && roi == (stage == "full" ? 1 : 2), "Interrupted \(stage) results cannot populate either cache after \(fault)")
                expect(isTitle(after) && owner.actions.isEmpty, "A fresh explicit retry after \(fault) only observes current evidence without phone input")
            }
        }
        var negativeFull = 0, negativeROI = 0
        let negative = PhoneHarnessRuntime(executor: MouseExecutor(), memoryURL: directory.appendingPathComponent("negative.json"), recognize: { _ in
            negativeFull += 1; return candidate
        }, recognizeWorkflowTitle: { _ in negativeROI += 1; return [] })
        let negativeFrame = frame()
        let noTitle1 = try await negative.workflowSnapshot(negativeFrame)
        let noTitle2 = try await negative.workflowSnapshot(negativeFrame.confirmed(at: Date()))
        try record("negative raw result", ["fullCalls": negativeFull, "roiCalls": negativeROI, "inventedTitle": isTitle(noTitle1) || isTitle(noTitle2)])
        expect(negativeFull == 1 && negativeROI == 1 && !isTitle(noTitle1) && !isTitle(noTitle2), "An empty real ROI result may be memoized without manufacturing a title or identity")

        let fullGate = RuntimeCacheGate(), roiGate = RuntimeCacheGate()
        var concurrentFull = 0, concurrentROI = 0
        let concurrent = PhoneHarnessRuntime(executor: MouseExecutor(), memoryURL: directory.appendingPathComponent("concurrent-miss.json"), recognize: { _ in
            concurrentFull += 1; await fullGate.wait(); return candidate
        }, recognizeWorkflowTitle: { _ in concurrentROI += 1; await roiGate.wait(); return [title] })
        let concurrentFrame = frame()
        let first = Task { try await concurrent.workflowSnapshot(concurrentFrame) }
        let second = Task { try await concurrent.workflowSnapshot(concurrentFrame) }
        try await waitForGate(fullGate, count: 2, name: "two concurrent full misses")
        fullGate.releaseAll()
        try await waitForGate(roiGate, count: 2, name: "two concurrent ROI misses")
        roiGate.releaseAll()
        let concurrentResults = try await [first.value, second.value]
        _ = try await concurrent.workflowSnapshot(concurrentFrame.confirmed(at: Date()))
        try record("concurrent initial misses remain separate", ["callers": 2, "fullCalls": concurrentFull, "roiCalls": concurrentROI])
        expect(concurrentFull == 2 && concurrentROI == 2 && concurrentResults.allSatisfy(isTitle), "This bounded pass does not pretend to coalesce concurrent first misses; a subsequent sequential read reuses their completed result")
        expect(ModelProbe.calls == modelBefore && executor.actions.isEmpty, "All memo tests leave model and input counters unchanged")
        print("\(checks) additional runtime pixel-cache checks passed (injected OCR only; concurrent initial misses measured, not coalesced).")
        return checks
    }
}
