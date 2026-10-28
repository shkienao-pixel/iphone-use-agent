import Foundation
import CoreGraphics

@main struct SemanticInputLeaseChecks {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        var reports: [[String: Any]] = []
        let faults = ["pixels", "captureStopped", "connection", "accessory", "runtime", "notReady", "missingFrame", "unchangedIdle"]
        let requests: [PhoneHarnessRequest] = [.init(operation: .tap, target: "Continue"), .init(operation: .type_text, text: "hello")]
        func later(than boundary: Date) async -> Date {
            var now = Date()
            while now <= boundary { await Task.yield(); now = Date() }
            return now
        }
        func elements() -> [PhoneUIElement] {
            [("Continue", 0.3), ("space", 0.8), ("return", 0.9)].map {
                .init(id: $0.0, label: $0.0, rect: .init(x: 0.4, y: $0.1, width: 0.2, height: 0.04), source: "ocr")
            }
        }
        for request in requests { for stage in ["ocrReturn", "beforeDispatch"] { for fault in faults {
            let name = request.operation.rawValue + "-" + stage + "-" + fault
            let capture = CaptureService(), executor = MouseExecutor(), id = UUID()
            let origin = ScreenFrame(image: UIImage(shade: 1), jpeg: Data([1,2,3]), capturedAt: Date(),
                sourceWidth: 2, sourceHeight: 2, fullDisplay: true, captureID: id)
            capture.frozenFrame = origin
            var runtime: PhoneHarnessRuntime!
            var mutated = false, providerCalls = 0
            func mutate() {
                guard !mutated else { return }; mutated = true
                switch fault {
                case "pixels": capture.frozenFrame = ScreenFrame(image: UIImage(shade: 0), jpeg: Data([4,5,6]), capturedAt: Date(), sourceWidth: 2, sourceHeight: 2, fullDisplay: true, captureID: id)
                case "captureStopped": capture.running = false
                case "connection": executor.ble.pointerConnectionGeneration = UUID()
                case "accessory": executor.ble.selectedID = "other-device"
                case "runtime": runtime.reset()
                case "notReady": executor.ble.ready = false
                case "missingFrame": capture.frozenFrame = nil
                default: capture.frozenFrame = ScreenFrame(image: origin.image, jpeg: origin.jpeg, capturedAt: origin.capturedAt, sourceWidth: 2, sourceHeight: 2, fullDisplay: true, confirmedAt: Date(), captureID: id)
                }
            }
            runtime = PhoneHarnessRuntime(executor: executor, memoryURL: directory.appendingPathComponent(name + ".json"), recognize: { _ in
                await Task.yield()
                if stage == "ocrReturn" { mutate() }
                return elements()
            }, contextCurrent: {
                providerCalls += 1
                return .init(frame: capture.frame, running: capture.running, selectedDeviceID: executor.ble.selectedID,
                    accessoryReady: executor.ble.ready, connectionGeneration: executor.ble.pointerConnectionGeneration)
            })
            if stage == "beforeDispatch" { runtime.observationRecorder = { _, _ in mutate() } }
            var error = "none", completed = false
            do {
                _ = try await runtime.execute(request, frame: origin, mappedHome: false, nextFrame: { after in
                    let now = await later(than: after)
                    let frame = ScreenFrame(image: UIImage(shade: 1), jpeg: Data([7,8,9]), capturedAt: now, sourceWidth: 2, sourceHeight: 2, fullDisplay: true, captureID: id)
                    capture.frozenFrame = frame; return frame
                })
                completed = true
            } catch let failure { error = String(describing: failure) }
            let allowed = fault == "unchangedIdle"
            precondition(mutated && (executor.actions.count == (allowed ? 1 : 0)) && completed == allowed, name + ": " + error)
            precondition(providerCalls > 0, "live provider must be consulted")
            reports.append(["case": name, "inputCount": executor.actions.count, "completed": completed, "providerCalls": providerCalls, "error": error])
        }}}
        // A real select-all changes a nonempty query's highlight pixels. The
        // macro must admit a new observation before typing, while still stopping
        // if the post-selection page, connection or confirmation is unsafe.
        for fault in ["none", "overlay", "wrongScene", "connection", "staleConfirmation", "changedAfterOCR"] {
            let capture = CaptureService(), executor = MouseExecutor(), id = UUID()
            func e(_ label: String, _ x: Double, _ y: Double) -> PhoneUIElement {
                .init(id: label, label: label, rect: .init(x: x - 0.04, y: y - 0.015, width: 0.08, height: 0.03), source: "ocr")
            }
            let home = [e("Search", 0.5, 0.86), e("Phone", 0.2, 0.3), e("Safari", 0.5, 0.3), e("Settings", 0.8, 0.3)]
            let search = [e("Search", 0.4, 0.08), e("Cancel", 0.88, 0.08), e("Space", 0.5, 0.91), e("Return", 0.88, 0.91), e("Old query", 0.4, 0.12)]
            let results = search + [e("Apps", 0.15, 0.2), e("Settings", 0.3, 0.32)]
            let settings = [e("Settings", 0.2, 0.1), e("Wi-Fi", 0.2, 0.4), e("Bluetooth", 0.2, 0.5)]
            func frame(_ stage: UInt8, _ date: Date) -> ScreenFrame {
                ScreenFrame(image: UIImage(shade: CGFloat(stage) / 10), jpeg: Data([stage]), capturedAt: date,
                    sourceWidth: 2, sourceHeight: 2, fullDisplay: true, captureID: id)
            }
            let origin = frame(0, Date()); capture.frozenFrame = origin
            var reads = 0, selectionObserved = false
            let runtime = PhoneHarnessRuntime(executor: executor, memoryURL: directory.appendingPathComponent("macro-\(fault).json"), recognize: { observed in
                switch observed.jpeg.first! {
                case 0: return home
                case 1: return search
                case 2:
                    selectionObserved = true
                    if fault == "connection" { executor.ble.pointerConnectionGeneration = UUID() }
                    if fault == "overlay" { return search + [e("Allow", 0.5, 0.5)] }
                    return fault == "wrongScene" ? settings : search
                case 3: return results
                default: return settings
                }
            }, contextCurrent: {
                .init(frame: capture.frame, running: capture.running, selectedDeviceID: executor.ble.selectedID,
                    accessoryReady: executor.ble.ready, connectionGeneration: executor.ble.pointerConnectionGeneration)
            })
            runtime.observationRecorder = { observed, _ in
                if fault == "changedAfterOCR", observed.jpeg.first == 2 { capture.frozenFrame = frame(9, Date()) }
            }
            var completed = false
            do {
                _ = try await runtime.execute(.init(operation: .open_app, target: "Settings"), frame: origin, mappedHome: false, nextFrame: { after in
                    reads += 1
                    let date = fault == "staleConfirmation" && reads == 2 ? after : await later(than: after)
                    let next = frame(UInt8(reads), date); capture.frozenFrame = next; return next
                })
                completed = true
            } catch { }
            if fault == "none" {
                precondition(completed && selectionObserved && reads == 4 && executor.actions == [.tap, .press_key, .type, .tap], "select-all must refresh and finish the normal macro")
            } else {
                precondition(!completed && reads == 2 && executor.actions == [.tap, .press_key], "unsafe selection must not type: " + fault)
            }
            reports.append(["case": "multi-input-" + fault, "inputCount": executor.actions.count, "completed": completed, "reads": reads])
        }
        // Populate the OCR cache through context(), then change the live pixels
        // exactly at the execution cache-hit validation (after lease admission).
        for changeOnCacheHit in [false, true] {
            let capture = CaptureService(), executor = MouseExecutor(), id = UUID()
            let origin = ScreenFrame(image: UIImage(), jpeg: Data([1]), capturedAt: Date(), sourceWidth: 2, sourceHeight: 2, fullDisplay: true, captureID: id)
            capture.frozenFrame = origin
            var armed = false, calls = 0, recognitions = 0
            let runtime = PhoneHarnessRuntime(executor: executor, memoryURL: directory.appendingPathComponent("cache-\(changeOnCacheHit).json"), recognize: { _ in
                recognitions += 1; return elements()
            }, contextCurrent: {
                if armed { calls += 1 }
                if armed && changeOnCacheHit && calls == 2 {
                    capture.frozenFrame = ScreenFrame(image: UIImage(shade: 0), jpeg: Data([2]), capturedAt: Date(), sourceWidth: 2, sourceHeight: 2, fullDisplay: true, captureID: id)
                }
                return .init(frame: capture.frame, running: capture.running, selectedDeviceID: executor.ble.selectedID,
                    accessoryReady: executor.ble.ready, connectionGeneration: executor.ble.pointerConnectionGeneration)
            })
            _ = try await runtime.context(for: origin); armed = true
            do {
                _ = try await runtime.execute(requests[0], frame: origin, mappedHome: false, nextFrame: { _ in
                    throw AgentError.message("fixture stops after dispatch")
                })
            } catch { }
            precondition(recognitions == 1, "second observation must exercise the cache")
            precondition(executor.actions.count == (changeOnCacheHit ? 0 : 1), "cache-hit binding check")
            reports.append(["case": "cache-change-\(changeOnCacheHit)", "inputCount": executor.actions.count, "recognitions": recognitions, "providerCalls": calls])
        }
        let data = try JSONSerialization.data(withJSONObject: ["offlineOnly": true, "cases": reports], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("semantic-input-results.json"))
        print("Semantic input leases: \(reports.count) cases passed; actual runtime/lease/frame, synthetic OCR/BLE, no device or network")
    }
}
