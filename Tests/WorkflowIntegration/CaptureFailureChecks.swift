import Foundation

/// Production capture adapter + real runtime; only the pixel/callback/HID
/// boundary is synthetic. Explicit invalid timestamps are negative fixtures.
@MainActor enum CaptureFailureChecks {
    static func run(folder: URL, elements: [PhoneUIElement]) async throws -> Int {
        var count = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); count += 1 }
        func rejected(_ gui: PhoneWorkflowCaptureDriver, stage: WorkflowCaptureFailure.Stage,
                      predicates: [WorkflowCaptureFailure.Predicate], after: Date = .distantPast) async throws -> WorkflowCaptureFailure {
            do { _ = try await gui.read(after: after); preconditionFailure("Expected capture rejection") }
            catch let failure as WorkflowCaptureFailure {
                expect(failure.stage == stage, "Failure reports the actual rejected capture stage: expected \(stage.rawValue), got \(failure.stage.rawValue)")
                expect(Set(predicates).isSubset(of: Set(failure.failedPredicates)), "Failure identifies each independently evaluated predicate")
                expect(gui.lastFailure == failure, "Last failure is the exact structured error, not a previous stage")
                expect(failure.json.utf8.count <= 2400 && failure.schemaVersion == 1,
                       "Stable schema and bounded JSON fit existing durable receipt reason fields")
                expect(failure.localizedDescription.utf8.count <= 450,
                       "The entire compact error survives existing 500/700-character receipt limits")
                let decoded = try JSONDecoder().decode(WorkflowCaptureFailure.self, from: Data(failure.json.utf8))
                expect(decoded == failure, "Failure evidence survives a real Codable round trip")
                return failure
            }
        }
        for mode in ["stopped", "not-full", "no-id", "size", "source-size", "unready", "pixel-after-confirmation", "old-confirmation", "future-confirmation", "no-current"] {
            let tape = CaptureReplay(folder: folder)
            var origin = tape.show(elements)
            var current = origin
            var predicates: [WorkflowCaptureFailure.Predicate]
            switch mode {
            case "stopped": tape.capture.running = false; predicates = [.captureRunning, .currentFramePresent]
            case "not-full": origin.fullDisplay = false; current = origin; predicates = [.observedFullDisplay, .currentFullDisplay]
            case "no-id": origin = ScreenFrame(capturedAt: origin.capturedAt); current = origin; predicates = [.captureIDPresent]
            case "size": current.width += 1; predicates = [.currentDimensionsMatch]
            case "source-size": current.sourceHeight += 1; predicates = [.currentSourceDimensionsMatch]
            case "unready": tape.executor.ble.ready = false; predicates = [.accessoryReady]
            case "pixel-after-confirmation": origin = origin.confirmed(at: origin.capturedAt.addingTimeInterval(-0.1)); current = origin; predicates = [.pixelBeforeConfirmation]
            case "old-confirmation": origin = tape.show(elements, at: Date().addingTimeInterval(-1.6)); current = origin; predicates = [.confirmationAgeValid]
            case "future-confirmation": origin = origin.confirmed(at: Date().addingTimeInterval(0.2)); current = origin; predicates = [.confirmationAgeValid]
            default: tape.capture.frameProvider = { nil }; predicates = [.currentFramePresent]
            }
            tape.capture.frozenFrame = current
            let gui = tape.driver(initial: origin)
            let failure = try await rejected(gui, stage: .beforeObservation, predicates: predicates)
            expect(tape.recognitions == 0 && tape.executor.actions.isEmpty, "Invalid host evidence stops before OCR or input: " + mode)
            if mode == "old-confirmation" { expect((failure.timings.confirmationAgeMs ?? 0) >= 1500, "The 1.5-second rejection records the actual confirmation age") }
            if mode == "future-confirmation" { expect((failure.timings.confirmationAgeMs ?? 0) < 0, "A future confirmation is diagnosed and remains rejected") }
            if ["size", "source-size"].contains(mode) { expect(failure.samePixelsAsCurrent == false, "A matching timestamp alone does not claim identical pixels across changed geometry") }
            gui.diagnosticOperationID = "new-operation"
            expect(gui.lastFailure == nil, "A new operation cannot display a prior operation's failure")
        }

        let equal = CaptureReplay(folder: folder), equalFrame = equal.show(elements)
        let equalGUI = PhoneWorkflowCaptureDriver(capture: equal.capture, executor: equal.executor, harness: equal.harness,
            initial: equalFrame, next: { _ in equalFrame })
        let equalFailure = try await rejected(equalGUI, stage: .waiting, predicates: [.confirmationAfterBoundary], after: equalFrame.confirmedAt)
        expect(equalFailure.timings.confirmationMinusBoundaryMs == 0 && equal.recognitions == 0,
               "Exactly equal native-presentation watermarks retain strict > and expose zero relative lag")

        let throwing = CaptureReplay(folder: folder), throwingFrame = throwing.show(elements)
        let sensitive = "PRIVATE_OCR_ACCOUNT_FILENAME_DO_NOT_EXPORT"
        let throwingGUI = PhoneWorkflowCaptureDriver(capture: throwing.capture, executor: throwing.executor, harness: throwing.harness,
            initial: throwingFrame, next: { _ in throw AgentError.message(sensitive) })
        let callbackFailure = try await rejected(throwingGUI, stage: .waiting, predicates: [.nextFrameDelivered], after: throwingFrame.confirmedAt)
        expect(!callbackFailure.json.contains(sensitive) && !callbackFailure.localizedDescription.contains(sensitive) &&
               !callbackFailure.json.contains(throwing.stream.uuidString) && !callbackFailure.json.contains(throwing.executor.ble.selectedID!),
               "JSON and error descriptions contain no upstream/private text or capture/accessory identifier")
        expect(callbackFailure.timings.waitElapsedMs.map { $0 >= 0 } == true, "Real monotonic wait duration is available even when the source throws")

        for mode in ["stream", "accessory", "stopped", "slow"] {
            let tape = CaptureReplay(folder: folder), frame = tape.show(elements)
            tape.onRecognize = {
                if mode == "slow" { try await Task.sleep(nanoseconds: 1_550_000_000) }
                else if mode == "stream" { _ = tape.show(elements, stream: UUID()) }
                else if mode == "accessory" { tape.executor.ble.selectedID = "changed-accessory" }
                else { tape.capture.running = false }
            }
            let gui = tape.driver(initial: frame)
            // The paired workflow lease rejects source/stream changes at the
            // OCR await boundary, before an invalid observation can return.
            let stage: WorkflowCaptureFailure.Stage = .observation
            let predicate: WorkflowCaptureFailure.Predicate = mode == "stream" ? .currentCaptureMatches :
                (mode == "accessory" ? .expectedAccessoryMatches : (mode == "stopped" ? .captureRunning : .confirmationAgeValid))
            let failure = try await rejected(gui, stage: stage, predicates: [predicate])
            expect(tape.executor.actions.isEmpty && tape.recognitions == 1 && tape.nextCalls == 0,
                   "Awaited OCR rejection performs no retry, fresh-frame request or input: " + mode)
            expect(failure.timings.observationElapsedMs.map { $0 >= 0 } == true, "Observed duration measures the actual awaited OCR call: " + mode)
            if mode == "slow" {
                expect((failure.timings.observationElapsedMs ?? 0) >= 1500 && failure.failedPredicates.contains(.runtimeObservationAccepted),
                       "Slow OCR is identified without relaxing either runtime or adapter freshness validation")
            }
        }

        let cancelled = CaptureReplay(folder: folder), cancelledFrame = cancelled.show(elements)
        cancelled.onRecognize = { throw CancellationError() }
        let cancelledGUI = cancelled.driver(initial: cancelledFrame)
        do { _ = try await cancelledGUI.read(); preconditionFailure("Expected cancellation") }
        catch is CancellationError {
            expect(cancelledGUI.lastFailure?.stage == .cancelled && cancelled.executor.actions.isEmpty,
                   "Cancellation retains its original error type and a separate non-input diagnostic stage")
        }
        for mode in ["tap", "scroll"] {
            let tape = CaptureReplay(folder: folder), gui = tape.driver()
            let cancelledBeforeBinding = await Task {
                withUnsafeCurrentTask { $0?.cancel() }
                do {
                    if mode == "tap" { try await gui.tap(elements[0]) }
                    else { try await gui.scroll(older: true) }
                    return false
                } catch is CancellationError { return true }
                catch { return false }
            }.value
            expect(cancelledBeforeBinding && gui.lastFailure?.stage == .cancelled && tape.executor.actions.isEmpty,
                   "Cancellation takes precedence over missing/stale target binding before any input: " + mode)
        }

        // A real idle callback can confirm unchanged old pixels. Only that
        // explicitly delivered synthetic callback advances confirmation here.
        let idle = CaptureReplay(folder: folder)
        let oldPixels = idle.show(elements, at: Date().addingTimeInterval(-10))
        let confirmed = oldPixels.confirmed(at: Date())
        idle.capture.frozenFrame = confirmed
        let idleGUI = idle.driver(initial: confirmed)
        let (firstIdle, snapshot) = try await idleGUI.read()
        try await Task.sleep(nanoseconds: 2_000_000)
        idle.capture.frozenFrame = oldPixels.confirmed(at: Date())
        let (secondIdle, _) = try await idleGUI.read()
        expect(firstIdle.capturedAt == oldPixels.capturedAt && secondIdle.capturedAt == oldPixels.capturedAt &&
               secondIdle.confirmedAt > firstIdle.confirmedAt,
               "Idle confirmation preserves the exact original pixel time while crossing the real read boundary")
        let target = snapshot.elements.first { $0.source == "ocr" }!
        try await idleGUI.tap(target)
        expect(idle.executor.actions == [.tap] && idleGUI.lastFailure == nil,
               "New real confirmation of the same pixels allows one current-element tap without demanding a new pixel timestamp")

        let changed = CaptureReplay(folder: folder), old = changed.show(elements), changedGUI = changed.driver(initial: old)
        let (_, observed) = try await changedGUI.read()
        _ = changed.show(elements)
        do { try await changedGUI.tap(observed.elements[0]); preconditionFailure("Expected changed-pixel rejection") }
        catch let failure as WorkflowCaptureFailure {
            expect(failure.stage == .actionBinding && failure.failedPredicates.contains(.currentPixelsMatch) &&
                   (failure.timings.currentPixelMinusObservedMs ?? 0) > 0 && failure.samePixelsAsCurrent == false && changed.executor.actions.isEmpty,
                   "Actual newer pixels retain the exact-timestamp input guard and expose relative change without raw timestamps")
        }
        _ = try await changedGUI.read()
        expect(changedGUI.lastFailure == nil, "A successful read clears prior failure metadata")

        let normalized = WorkflowCaptureFailure(stage: .beforeObservation, failedPredicates: [.confirmationAgeValid],
            timings: .init(confirmationAgeMs: .nan, pixelAgeMs: .infinity, currentConfirmationAgeMs: -.infinity))
        let decodedNormalized = try JSONDecoder().decode(WorkflowCaptureFailure.self, from: Data(normalized.json.utf8))
        expect(normalized.timings.confirmationAgeMs == nil && normalized.timings.pixelAgeMs == nil &&
               normalized.timings.currentConfirmationAgeMs == nil && decodedNormalized == normalized,
               "NaN/Inf timings become absent and cannot replace the original failure with a JSON encoding error")
        let all = WorkflowCaptureFailure(stage: .afterObservation, failedPredicates: WorkflowCaptureFailure.Predicate.allCases)
        let compact = try JSONSerialization.jsonObject(with: Data(all.compactJSON.utf8)) as! [String: Any]
        let codes = compact["failedPredicateCodes"] as! [String]
        expect(all.localizedDescription.utf8.count <= 450 && Set(codes).count == WorkflowCaptureFailure.Predicate.allCases.count &&
               codes.compactMap(WorkflowCaptureFailure.Predicate.init(compactCode:)) == WorkflowCaptureFailure.Predicate.allCases,
               "Every schema-1 predicate has a unique explicit reversible short code; worst-case compact JSON is complete, not cut")
        expect(WorkflowCaptureFailure.Predicate(compactCode: "unknown") == nil,
               "An unknown compact code cannot be guessed into a known predicate")
        for (stage, predicates, text) in [(WorkflowCaptureFailure.Stage.waiting, [WorkflowCaptureFailure.Predicate.confirmationAfterBoundary], "新画面未到达"),
            (.beforeObservation, [.confirmationAgeValid], "画面时间无效或已过期"),
            (.afterObservation, [.expectedAccessoryMatches], "设备或共享已变化"),
            (.targetBinding, [.observedTargetMatches], "目标已失效")] {
            let failure = WorkflowCaptureFailure(stage: stage, failedPredicates: predicates)
            expect(failure.localizedDescription.hasPrefix(text) && failure.localizedDescription.utf8.count <= 450,
                   "Fixed human-readable capture reasons are actionable, bounded and contain no upstream/private text")
        }

        let archived = CaptureReplay(folder: folder), archiveFrame = archived.show(elements)
        let archiveStore = WorkflowDiagnosticsStore(directory: folder.appendingPathComponent("capture-predicate-archive"))
        let archiveGUI = PhoneWorkflowCaptureDriver(capture: archived.capture, executor: archived.executor, harness: archived.harness,
            initial: archiveFrame, next: { _ in archiveFrame }, diagnostics: archiveStore)
        _ = try await archiveGUI.read()
        _ = try await rejected(archiveGUI, stage: .waiting, predicates: [.confirmationAfterBoundary])
        let record = archiveStore.records.last!
        let decodedArchive = try JSONDecoder().decode(WorkflowCaptureFailure.self, from: Data(record.context.result!.utf8))
        expect(decodedArchive == archiveGUI.lastFailure && record.context.capturedAt == archiveFrame.capturedAt &&
               record.context.boundary == .failed,
               "Full timing JSON persists in the diagnostic result next to the exact last valid observation, without relabeling it as a new failure screenshot")
        for mode in ["tap", "scroll"] {
            let tape = CaptureReplay(folder: folder), frame = tape.show(elements)
            let store = WorkflowDiagnosticsStore(directory: folder.appendingPathComponent("executor-failure-" + mode))
            let gui = PhoneWorkflowCaptureDriver(capture: tape.capture, executor: tape.executor, harness: tape.harness,
                initial: frame, diagnostics: store)
            let (_, snapshot) = try await gui.read()
            let target = snapshot.elements[0]
            var changedTarget = target; changedTarget.rect.y += 0.01
            do { try await gui.tap(changedTarget); preconditionFailure("Expected target failure") }
            catch is WorkflowCaptureFailure { }
            expect(gui.lastFailure?.failedPredicates.contains(.observedTargetMatches) == true,
                   "The earlier binding failure is present before the independent native executor error fixture")
            let native = AgentError.message("synthetic executor native failure")
            tape.executor.executeError = native
            do {
                if mode == "tap" { try await gui.tap(target) }
                else { try await gui.scroll(older: true) }
                preconditionFailure("Expected native executor failure")
            } catch {
                expect(!(error is WorkflowCaptureFailure) && error.localizedDescription == native.localizedDescription,
                       "The current executor's original error is not replaced by an earlier capture predicate")
            }
            expect(gui.lastFailure == nil && store.records.last?.context.result == nil &&
                   store.records.last?.context.reason == native.localizedDescription && tape.executor.executeCalls == 1 && tape.executor.actions.isEmpty,
                   "Each input attempt clears prior failure metadata, including the archived result; no fake input was dispatched: " + mode)
        }
        return count
    }
}
