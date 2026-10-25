import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Only fixed predicates and relative timings cross this diagnostic boundary.
/// It contains no OCR, filename, account, device/session ID, screenshot or
/// upstream error description. A failure is not a submission outcome.
struct WorkflowCaptureFailure: Error, LocalizedError, Codable, Equatable {
    enum Stage: String, Codable {
        case externalBoundary, waiting, beforeObservation, observation, afterObservation
        case targetBinding, actionBinding, actionValidation, calibration, cancelled
    }
    enum Predicate: String, Codable, Hashable, CaseIterable {
        case externalBoundaryFinite, confirmationAfterBoundary, captureWaitCompleted, nextFrameDelivered
        case captureRunning, observedFullDisplay, captureIDPresent, observedDimensionsPositive
        case pixelTimestampFinite, confirmationTimestampFinite, pixelBeforeConfirmation, confirmationAgeValid
        case accessoryReady, currentFramePresent, currentCaptureMatches, currentFullDisplay
        case currentDimensionsMatch, currentSourceDimensionsMatch, expectedCaptureMatches
        case expectedDimensionsMatch, expectedSourceDimensionsMatch, expectedAccessoryMatches
        case runtimeObservationAccepted, overlayClear, currentPixelsMatch, previousObservationPresent
        case observedTargetMatches, observedTargetSourceAllowed, calibrationAccepted, taskNotCancelled
        case sourcePixelsValid, currentImageObjectMatches, currentCGImageObjectMatches, currentJPEGMatches
        case confirmationNotRegressed, runtimeGenerationMatches, connectionGenerationMatches
        /// Schema-1 wire codes are explicit and never depend on enum order.
        var compactCode: String {
            switch self {
            case .externalBoundaryFinite: return "b0"
            case .confirmationAfterBoundary: return "b1"
            case .captureWaitCompleted: return "w0"
            case .nextFrameDelivered: return "w1"
            case .captureRunning: return "c0"
            case .observedFullDisplay: return "c1"
            case .captureIDPresent: return "c2"
            case .observedDimensionsPositive: return "c3"
            case .pixelTimestampFinite: return "c4"
            case .confirmationTimestampFinite: return "c5"
            case .pixelBeforeConfirmation: return "c6"
            case .confirmationAgeValid: return "c7"
            case .accessoryReady: return "c8"
            case .currentFramePresent: return "c9"
            case .currentCaptureMatches: return "cA"
            case .currentFullDisplay: return "cB"
            case .currentDimensionsMatch: return "cC"
            case .currentSourceDimensionsMatch: return "cD"
            case .expectedCaptureMatches: return "cE"
            case .expectedDimensionsMatch: return "cF"
            case .expectedSourceDimensionsMatch: return "cG"
            case .expectedAccessoryMatches: return "cH"
            case .runtimeObservationAccepted: return "o0"
            case .overlayClear: return "o1"
            case .currentPixelsMatch: return "a0"
            case .previousObservationPresent: return "a1"
            case .observedTargetMatches: return "a2"
            case .observedTargetSourceAllowed: return "a3"
            case .calibrationAccepted: return "a4"
            case .taskNotCancelled: return "z0"
            case .sourcePixelsValid: return "l0"
            case .currentImageObjectMatches: return "l1"
            case .currentCGImageObjectMatches: return "l2"
            case .currentJPEGMatches: return "l3"
            case .confirmationNotRegressed: return "l4"
            case .runtimeGenerationMatches: return "l5"
            case .connectionGenerationMatches: return "l6"
            }
        }
        init?(compactCode: String) {
            guard let value = Self.allCases.first(where: { $0.compactCode == compactCode }) else { return nil }
            self = value
        }
    }
    struct Timings: Codable, Equatable {
        let confirmationAgeMs: Double?
        let pixelAgeMs: Double?
        let currentConfirmationAgeMs: Double?
        let confirmationMinusBoundaryMs: Double?
        let currentPixelMinusObservedMs: Double?
        let waitElapsedMs: Double?
        let observationElapsedMs: Double?
        static func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0 : nil } }
        init(confirmationAgeMs: Double? = nil, pixelAgeMs: Double? = nil, currentConfirmationAgeMs: Double? = nil,
             confirmationMinusBoundaryMs: Double? = nil, currentPixelMinusObservedMs: Double? = nil,
             waitElapsedMs: Double? = nil, observationElapsedMs: Double? = nil) {
            self.confirmationAgeMs = Self.finite(confirmationAgeMs); self.pixelAgeMs = Self.finite(pixelAgeMs)
            self.currentConfirmationAgeMs = Self.finite(currentConfirmationAgeMs)
            self.confirmationMinusBoundaryMs = Self.finite(confirmationMinusBoundaryMs)
            self.currentPixelMinusObservedMs = Self.finite(currentPixelMinusObservedMs)
            self.waitElapsedMs = Self.finite(waitElapsedMs); self.observationElapsedMs = Self.finite(observationElapsedMs)
        }
    }
    let schemaVersion: Int
    let stage: Stage
    let failedPredicates: [Predicate]
    let timings: Timings
    let samePixelsAsCurrent: Bool?
    init(stage: Stage, failedPredicates: [Predicate], timings: Timings = .init(), samePixelsAsCurrent: Bool? = nil) {
        schemaVersion = 1; self.stage = stage; self.failedPredicates = failedPredicates
        self.timings = timings; self.samePixelsAsCurrent = samePixelsAsCurrent
    }
    /// A bounded JSON object also survives existing receipt reason fields.
    var json: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), data.count <= 2400 else {
            return "{\"schemaVersion\":1,\"diagnosticEncodingUnavailable\":true}"
        }
        return String(decoding: data, as: UTF8.self)
    }
    private struct Compact: Codable {
        var schemaVersion: Int
        var stage: Stage
        var failedPredicateCodes: [String]
    }
    var compactJSON: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let compact = Compact(schemaVersion: schemaVersion, stage: stage, failedPredicateCodes: failedPredicates.map(\.compactCode))
        guard let data = try? encoder.encode(compact), data.count <= 400 else {
            return "{\"schemaVersion\":1,\"diagnosticEncodingUnavailable\":true}"
        }
        return String(decoding: data, as: UTF8.self)
    }
    var humanReason: String {
        if stage == .externalBoundary { return "新画面边界无效，请重新开始流程" }
        if stage == .waiting { return "新画面未到达，已保留进度" }
        if stage == .cancelled { return "流程已取消，未继续输入" }
        if failedPredicates.contains(.confirmationAgeValid) || failedPredicates.contains(.pixelTimestampFinite) ||
            failedPredicates.contains(.confirmationTimestampFinite) || failedPredicates.contains(.pixelBeforeConfirmation) {
            return "画面时间无效或已过期，请重新读取"
        }
        if failedPredicates.contains(.overlayClear) { return "当前页面有遮挡，请处理后重新读取" }
        if stage == .targetBinding { return "目标已失效，请重新读取页面" }
        if stage == .actionBinding { return "定位后画面已变化，请重新读取" }
        if stage == .calibration { return "配件定位未就绪，请重新校准" }
        if failedPredicates.contains(.expectedAccessoryMatches) || failedPredicates.contains(.accessoryReady) ||
            failedPredicates.contains(.currentCaptureMatches) || failedPredicates.contains(.expectedCaptureMatches) ||
            failedPredicates.contains(.captureRunning) || failedPredicates.contains(.currentFramePresent) ||
            stage == .beforeObservation || stage == .afterObservation {
            return "设备或共享已变化，已停止输入"
        }
        return "画面识别未通过核验，请重新读取"
    }
    var errorDescription: String? { humanReason + "；captureFailure=" + compactJSON }
}

/// The app's single active GUI controller supplies only real captured pixels.
/// Domain collectors never synthesize OCR, timestamps, identities or coordinates.
@MainActor final class PhoneWorkflowCaptureDriver {
    let capture: CaptureService
    let executor: MouseExecutor
    let harness: PhoneHarnessRuntime
    private let initial: ScreenFrame?
    private let next: (@MainActor (Date) async throws -> ScreenFrame)?
    private var consumedInitial = false
    private var expected: (UUID, Int, Int, Int, Int, String?)?
    private var previous: ScreenFrame?
    private var previousProof: WorkflowObservationProof?
    private var previousConnectionGeneration: UUID?
    private var lastSnapshot: PhoneUISnapshot?
    private var inputEnded = Date.distantPast
    var menuPolicy: ((PhoneUISnapshot) -> Bool)?
    private let diagnostics:WorkflowDiagnosticsStore?
    var diagnosticWorkflowID:String? { didSet { if oldValue != diagnosticWorkflowID { lastFailure = nil } } }
    var diagnosticOperationID:String? { didSet { if oldValue != diagnosticOperationID { lastFailure = nil } } }
    var protectSubmissionEvidence=false
    private var diagnosticFrame:(ScreenFrame,PhoneUISnapshot)?
    private(set) var diagnosticRecordingError:String?
    private(set) var lastFailure: WorkflowCaptureFailure?
    private var attemptFrame: ScreenFrame?
    private var attemptBoundary = Date.distantPast
    private var waitElapsedMs: Double?
    private var observationElapsedMs: Double?


    init(capture: CaptureService, executor: MouseExecutor, harness: PhoneHarnessRuntime,
         initial: ScreenFrame? = nil, next: (@MainActor (Date) async throws -> ScreenFrame)? = nil, diagnostics:WorkflowDiagnosticsStore?=nil) {
        self.capture = capture; self.executor = executor; self.harness = harness
        self.initial = initial; self.next = next; self.diagnostics=diagnostics
    }
    /// External native events (for example viewDidAppear) are independent of
    /// this driver's last input. Their real watermark must reach capture wait.
    func read(after externalBoundary: Date = .distantPast) async throws -> (ScreenFrame, PhoneUISnapshot) {
        lastFailure = nil; attemptFrame = nil; attemptBoundary = externalBoundary
        waitElapsedMs = nil; observationElapsedMs = nil
        do {
            let result = try await readCurrent(after: externalBoundary)
            lastFailure = nil
            return result
        }
        catch {
            if error is CancellationError { _ = failure(.cancelled, [.taskNotCancelled]) }
            recordOutcome(error is CancellationError ? .paused : .failed,reason:error.localizedDescription,result:lastFailure?.json)
            throw error
        }
    }
    private func readCurrent(after externalBoundary: Date) async throws -> (ScreenFrame, PhoneUISnapshot) {
        try Task.checkCancellation()
        guard externalBoundary.timeIntervalSinceReferenceDate.isFinite else { throw failure(.externalBoundary, [.externalBoundaryFinite]) }
        let boundary = max(externalBoundary, max(inputEnded, previous?.confirmedAt ?? .distantPast))
        attemptBoundary = boundary
        let frame: ScreenFrame
        if !consumedInitial, let initial, initial.confirmedAt > boundary {
            consumedInitial = true; frame = initial
        } else if let current = capture.frame, current.confirmedAt > boundary {
            frame = current
        } else if let next {
            let started = ProcessInfo.processInfo.systemUptime
            do { frame = try await next(boundary) }
            catch is CancellationError {
                waitElapsedMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
                throw CancellationError()
            }
            catch {
                waitElapsedMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
                throw failure(.waiting, [.nextFrameDelivered])
            }
            waitElapsedMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
            try Task.checkCancellation()
        }
        else {
            let started = ProcessInfo.processInfo.systemUptime
            let completed: Bool
            do { completed = try await capture.waitForFrame(after: boundary, timeout: 6) }
            catch is CancellationError {
                waitElapsedMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
                throw CancellationError()
            }
            catch {
                waitElapsedMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
                throw failure(.waiting, [.captureWaitCompleted])
            }
            waitElapsedMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
            try Task.checkCancellation()
            guard let current = capture.frame, current.confirmedAt > boundary else {
                throw failure(.waiting, (completed ? [] : [.captureWaitCompleted]) +
                    (capture.frame == nil ? [.currentFramePresent] : []) + [.confirmationAfterBoundary])
            }
            frame = current
        }
        attemptFrame = frame
        guard frame.confirmedAt > boundary else {
            throw failure(.waiting, [.confirmationAfterBoundary])
        }
        try validate(frame, stage: .beforeObservation)
        let started = ProcessInfo.processInfo.systemUptime
        let observation: WorkflowObservationPair
        do {
            observation = try await harness.workflowObservation(frame, after: boundary, current: { [self] in
                WorkflowObservationState(frame: capture.frame, running: capture.running,
                    selectedDeviceID: executor.ble.selectedID, accessoryReady: executor.ble.ready,
                    connectionGeneration: executor.ble.pointerConnectionGeneration)
            }, allowingMenu: menuPolicy)
        }
        catch is CancellationError {
            observationElapsedMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
            throw CancellationError()
        }
        catch let error as WorkflowLeaseFailure {
            observationElapsedMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
            throw failure(.observation, [.runtimeObservationAccepted] + error.predicates.map(Self.capturePredicate))
        }
        catch {
            observationElapsedMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
            throw failure(.observation, [.runtimeObservationAccepted] + validationFailures(frame))
        }
        observationElapsedMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
        let confirmed: ScreenFrame
        do { confirmed = try harness.confirmWorkflowObservation(observation) }
        catch is CancellationError { throw CancellationError() }
        catch let error as WorkflowLeaseFailure { throw failure(.afterObservation, error.predicates.map(Self.capturePredicate)) }
        attemptFrame = confirmed
        try validate(confirmed, stage: .afterObservation)
        let snapshot = observation.snapshot
        diagnosticFrame=(confirmed,snapshot)
        recordOutcome(.observed,reason:snapshot.blockingOverlay ? "当前页面有遮挡或未排除的确认窗口" : nil)
        guard !snapshot.blockingOverlay else { throw failure(.afterObservation, [.overlayClear]) }
        previous = confirmed; lastSnapshot = snapshot
        previousProof = observation.proof; previousConnectionGeneration = observation.connectionGeneration
        return (confirmed, snapshot)
    }
    func currentDeviceKey() async throws -> String { try await read().1.deviceKey }
    private static func capturePredicate(_ predicate: WorkflowLeaseFailure.Predicate) -> WorkflowCaptureFailure.Predicate {
        switch predicate {
        case .sourcePixelsValid: return .sourcePixelsValid
        case .captureRunning: return .captureRunning
        case .currentFramePresent: return .currentFramePresent
        case .currentCaptureMatches: return .currentCaptureMatches
        case .currentPixelsMatch: return .currentPixelsMatch
        case .currentFullDisplay: return .currentFullDisplay
        case .currentDimensionsMatch: return .currentDimensionsMatch
        case .currentSourceDimensionsMatch: return .currentSourceDimensionsMatch
        case .currentImageObjectMatches: return .currentImageObjectMatches
        case .currentCGImageObjectMatches: return .currentCGImageObjectMatches
        case .currentJPEGMatches: return .currentJPEGMatches
        case .confirmationTimestampFinite: return .confirmationTimestampFinite
        case .pixelBeforeConfirmation: return .pixelBeforeConfirmation
        case .confirmationAgeValid: return .confirmationAgeValid
        case .confirmationNotRegressed: return .confirmationNotRegressed
        case .confirmationAfterBoundary: return .confirmationAfterBoundary
        case .expectedAccessoryMatches: return .expectedAccessoryMatches
        case .accessoryReady: return .accessoryReady
        case .connectionGenerationMatches: return .connectionGenerationMatches
        case .runtimeGenerationMatches: return .runtimeGenerationMatches
        }
    }
    private func validate(_ frame: ScreenFrame, stage: WorkflowCaptureFailure.Stage) throws {
        try Task.checkCancellation()
        let failed = validationFailures(frame)
        guard failed.isEmpty else { throw failure(stage, failed) }
        if expected == nil, let id = frame.captureID {
            expected = (id, frame.width, frame.height, frame.sourceWidth, frame.sourceHeight, executor.ble.selectedID)
        }
    }
    private func validationFailures(_ frame: ScreenFrame) -> [WorkflowCaptureFailure.Predicate] {
        let current = capture.frame, now = Date()
        var checks: [(WorkflowCaptureFailure.Predicate, Bool)] = [
            (.captureRunning, capture.running), (.observedFullDisplay, frame.fullDisplay), (.captureIDPresent, frame.captureID != nil),
            (.observedDimensionsPositive, frame.width > 0 && frame.height > 0 && frame.sourceWidth > 0 && frame.sourceHeight > 0),
            (.pixelTimestampFinite, frame.capturedAt.timeIntervalSinceReferenceDate.isFinite),
            (.confirmationTimestampFinite, frame.confirmedAt.timeIntervalSinceReferenceDate.isFinite),
            (.pixelBeforeConfirmation, frame.capturedAt <= frame.confirmedAt),
            (.confirmationAgeValid, (0..<1.5).contains(now.timeIntervalSince(frame.confirmedAt))),
            (.accessoryReady, executor.ble.ready), (.currentFramePresent, current != nil)
        ]
        if let current {
            checks += [(.currentCaptureMatches, current.captureID == frame.captureID), (.currentFullDisplay, current.fullDisplay),
                (.currentDimensionsMatch, current.width == frame.width && current.height == frame.height),
                (.currentSourceDimensionsMatch, current.sourceWidth == frame.sourceWidth && current.sourceHeight == frame.sourceHeight)]
        }
        if let expected {
            checks += [(.expectedCaptureMatches, frame.captureID == expected.0),
                (.expectedDimensionsMatch, frame.width == expected.1 && frame.height == expected.2),
                (.expectedSourceDimensionsMatch, frame.sourceWidth == expected.3 && frame.sourceHeight == expected.4),
                (.expectedAccessoryMatches, executor.ble.selectedID == expected.5)]
        }
        return checks.filter { !$0.1 }.map(\.0)
    }
    private func failure(_ stage: WorkflowCaptureFailure.Stage, _ predicates: [WorkflowCaptureFailure.Predicate]) -> WorkflowCaptureFailure {
        let current = capture.frame, frame = attemptFrame ?? previous, now = Date()
        let value = WorkflowCaptureFailure(stage: stage, failedPredicates: Array(Set(predicates)).sorted { $0.rawValue < $1.rawValue },
            timings: .init(confirmationAgeMs: frame.map { now.timeIntervalSince($0.confirmedAt) * 1000 },
                pixelAgeMs: frame.map { now.timeIntervalSince($0.capturedAt) * 1000 },
                currentConfirmationAgeMs: current.map { now.timeIntervalSince($0.confirmedAt) * 1000 },
                confirmationMinusBoundaryMs: attemptBoundary == .distantPast ? nil : frame.map { $0.confirmedAt.timeIntervalSince(attemptBoundary) * 1000 },
                currentPixelMinusObservedMs: frame.flatMap { observed in current.map { $0.capturedAt.timeIntervalSince(observed.capturedAt) * 1000 } },
                waitElapsedMs: waitElapsedMs, observationElapsedMs: observationElapsedMs),
            samePixelsAsCurrent: frame.flatMap { observed in current.map {
                $0.captureID == observed.captureID && $0.capturedAt == observed.capturedAt &&
                    $0.width == observed.width && $0.height == observed.height &&
                    $0.sourceWidth == observed.sourceWidth && $0.sourceHeight == observed.sourceHeight
            } })
        lastFailure = value
        return value
    }
    private func actionFrame() throws -> ScreenFrame {
        attemptFrame = previous
        let current = capture.frame
        var checks: [(WorkflowCaptureFailure.Predicate, Bool)] = [
            (.previousObservationPresent, previous != nil), (.currentFramePresent, current != nil)
        ]
        if let previousProof {
            checks += harness.workflowProofBindingFailures(previousProof).map { (Self.capturePredicate($0), false) }
            if let current { checks += previousProof.pixelFailures(current).map { (Self.capturePredicate($0), false) } }
        }
        if let connection = previousConnectionGeneration {
            checks.append((.connectionGenerationMatches, executor.ble.pointerConnectionGeneration == connection))
        }
        if let frame = previous, let current {
            checks += [(.confirmationNotRegressed, current.confirmedAt >= frame.confirmedAt),
                (.currentCaptureMatches, current.captureID == frame.captureID),
                (.currentPixelsMatch, current.capturedAt == frame.capturedAt),
                (.currentDimensionsMatch, current.width == frame.width && current.height == frame.height),
                (.currentSourceDimensionsMatch, current.sourceWidth == frame.sourceWidth && current.sourceHeight == frame.sourceHeight)]
        }
        let failed = checks.filter { !$0.1 }.map(\.0)
        guard failed.isEmpty, let current else { throw failure(.actionBinding, failed) }
        try validate(current, stage: .actionValidation)
        do { _ = try executor.validateCalibration(frame: current) }
        catch is CancellationError { throw CancellationError() }
        catch { throw failure(.calibration, [.calibrationAccepted]) }
        return current
    }
    func tap(_ element:PhoneUIElement) async throws {
        lastFailure = nil
        do {try await tapCurrent(element)} catch {
            if error is CancellationError { _ = failure(.cancelled, [.taskNotCancelled]) }
            recordOutcome(error is CancellationError ? .paused : .failed,action:"点击："+element.label,reason:error.localizedDescription,result:lastFailure?.json)
            throw error
        }
    }
    private func tapCurrent(_ element: PhoneUIElement) async throws {
        try Task.checkCancellation()
        let checks: [(WorkflowCaptureFailure.Predicate, Bool)] = [
            (.observedTargetMatches, lastSnapshot?.element(id: element.id) == element),
            (.observedTargetSourceAllowed, ["ocr", "local_visual"].contains(element.source))
        ]
        let failed = checks.filter { !$0.1 }.map(\.0)
        guard failed.isEmpty else { throw failure(.targetBinding, failed) }
        let frame = try actionFrame()
        recordOutcome(.beforeInput,action:"点击："+element.label)
        try await executor.execute(.init(kind: .tap, x: element.rect.centerX, y: element.rect.centerY,
            reason: "本地流程点击当前控件"), frame: frame)
        inputEnded = Date()
        recordOutcome(.afterInput,action:"点击："+element.label,result:"输入调用已返回；结果等待后续真实画面核验")
        try Task.checkCancellation()
    }
    func scroll(older:Bool, at element:PhoneUIElement? = nil) async throws {
        lastFailure = nil
        do {try await scrollCurrent(older:older, at:element)} catch {
            if error is CancellationError { _ = failure(.cancelled, [.taskNotCancelled]) }
            recordOutcome(error is CancellationError ? .paused : .failed,action:"滚动",reason:error.localizedDescription,result:lastFailure?.json)
            throw error
        }
    }
    private func scrollCurrent(older: Bool, at element: PhoneUIElement?) async throws {
        try Task.checkCancellation()
        if let element {
            let checks: [(WorkflowCaptureFailure.Predicate, Bool)] = [
                (.observedTargetMatches, element.rect.valid && lastSnapshot?.element(id: element.id) == element),
                (.observedTargetSourceAllowed, ["ocr", "local_visual"].contains(element.source))
            ]
            let failed = checks.filter { !$0.1 }.map(\.0)
            guard failed.isEmpty else { throw failure(.targetBinding, failed) }
        }
        let frame = try actionFrame()
        let action=older ? "向前读取 / 滚动" : "向后读取 / 滚动"
        recordOutcome(.beforeInput,action:action)
        try await executor.execute(.init(kind:.scroll,x:element?.rect.centerX,y:element?.rect.centerY,
            amount:older ? 3 : -3,reason:element == nil ? "本地流程有界滚动" : "定位当前列表后有界滚动"),frame:frame)
        inputEnded=Date()
        recordOutcome(.afterInput,action:action,result:"滚动调用已返回；结果等待后续真实画面核验")
        try Task.checkCancellation()
    }
    func recordOutcome(_ boundary:WorkflowDiagnosticBoundary,action:String?=nil,reason:String?=nil,result:String?=nil) {
        guard let diagnostics else{return}
        guard let (frame,snapshot)=diagnosticFrame,let captureID=frame.captureID else {
            diagnosticRecordingError="本次没有可用的整屏识别画面，关键截图与诊断未记录"
            return
        }
        do {
            _ = try diagnostics.record(jpeg:frame.jpeg,context:.init(workflowID:diagnosticWorkflowID,operationID:diagnosticOperationID,boundary:boundary,captureID:captureID,capturedAt:frame.capturedAt,confirmedAt:frame.confirmedAt,snapshot:snapshot,action:action.map{String($0.prefix(3000))},reason:reason.map{String($0.prefix(3000))},result:result.map{String($0.prefix(3000))},protectPendingSubmission:protectSubmissionEvidence))
            diagnosticRecordingError=nil
        } catch {diagnosticRecordingError=error.localizedDescription}
    }
    func returnToResults() async throws {
        guard let snapshot = lastSnapshot else { throw AgentError.message("没有当前页面") }
        let names = ["返回", "back", "搜索", "search"]
        let matches = snapshot.elements.filter {
            $0.source == "ocr" && $0.rect.centerX < 0.25 && $0.rect.centerY < 0.18 &&
                names.contains(PhonePageAdapters.normalized($0.label))
        }
        if matches.count == 1 { try await tap(matches[0]); return }
        guard matches.isEmpty,
              ["xiaohongshu.note", "xiaohongshu.comments"].contains(XiaohongshuPageAdapter.identity(in:snapshot,noteOpenedFromResults:true)?.scene ?? "") else {
            throw AgentError.message("没有唯一可见返回控件，已保存当前笔记，不猜返回坐标")
        }
        let visual = snapshot.elements.filter {
            $0.source == "local_visual" && ["视觉:返回", "视觉:关闭"].contains($0.label) &&
                $0.rect.centerX < 0.25 && $0.rect.centerY < 0.2
        }
        guard visual.count == 1 else {throw AgentError.message("当前笔记没有唯一实际返回图形，已保存进度")}
        try await tap(visual[0])
    }
}

@MainActor final class LiveXiaohongshuCollectionDriver: XiaohongshuCollectionDriving {
    let gui: PhoneWorkflowCaptureDriver
    init(gui: PhoneWorkflowCaptureDriver) { self.gui = gui }
    func read() async throws -> XiaohongshuCollectionFrame {
        let (frame, snapshot) = try await gui.read()
        let digest = PhoneRasterEvidence.sha256(frame.jpeg)
        let raster = frame.image.cgImage.flatMap { PhoneRasterEvidence.raster($0) }
        let selections = XiaohongshuPageAdapter.localSelectionEvidence(snapshot: snapshot, screenshotSHA256: digest) { x, y in
            guard let pixel = raster?.sample(x, y) else { return nil }
            return .init(red: pixel.red, green: pixel.green, blue: pixel.blue, alpha: pixel.alpha)
        }
        return .init(snapshot: snapshot, shareID: frame.captureID!.uuidString, width: frame.width, height: frame.height,
                     selectionEvidence: selections, screenshotSHA256: digest, confirmedAt: frame.confirmedAt)
    }
    func openNote(_ element: PhoneUIElement) async throws { try await gui.tap(element) }
    func returnToResults() async throws { try await gui.returnToResults() }
    func scrollResults(at element: PhoneUIElement) async throws { try await gui.scroll(older: false, at: element) }
    func tapObserved(_ element: PhoneUIElement) async throws { try await gui.tap(element) }
    func clipboardSnapshot(readText: Bool) async throws -> XiaohongshuClipboardSnapshot {
        #if canImport(UIKit)
        if readText, UIApplication.shared.applicationState != .active { throw XiaohongshuClipboardError.foregroundRequired }
        let clipboard = UIPasteboard.general
        return .init(changeCount: clipboard.changeCount, text: readText ? clipboard.string : nil, readAt: Date())
        #else
        throw XiaohongshuClipboardError.unsupported
        #endif
    }
    func resolveShortLink(_ url: URL) async throws -> XiaohongshuResolvedLink {
        try await XiaohongshuLinkResolver.resolve(url)
    }
}
