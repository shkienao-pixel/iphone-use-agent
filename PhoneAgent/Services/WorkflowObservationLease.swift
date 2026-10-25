import Foundation
import CoreGraphics

/// Read synchronously from the live capture slot and actual input connection.
/// Neither a timer nor a stored screenshot is a source of confirmation.
@MainActor struct WorkflowObservationState {
    let frame: ScreenFrame?
    let running: Bool
    let selectedDeviceID: String?
    let accessoryReady: Bool
    let connectionGeneration: UUID
}

struct WorkflowLeaseFailure: Error, LocalizedError {
    enum Predicate: String {
        case sourcePixelsValid, captureRunning, currentFramePresent, currentCaptureMatches
        case currentPixelsMatch, currentFullDisplay, currentDimensionsMatch, currentSourceDimensionsMatch
        case currentImageObjectMatches, currentCGImageObjectMatches, currentJPEGMatches
        case confirmationTimestampFinite, pixelBeforeConfirmation, confirmationAgeValid
        case confirmationNotRegressed, confirmationAfterBoundary, expectedAccessoryMatches
        case accessoryReady, connectionGenerationMatches, runtimeGenerationMatches
    }
    let predicates: [Predicate]
    var errorDescription: String? { "工作流当前画面或系统确认已变化，请重新读取" }
}

/// Pixel recognition reuse only. This deliberately contains no confirmation
/// timestamp, boundary, user authorization or submission result.
@MainActor struct WorkflowObservationProof {
    private let captureID: UUID
    private let capturedAt: Date
    private let jpeg: Data
    private let width: Int
    private let height: Int
    private let sourceWidth: Int
    private let sourceHeight: Int
    private let imageObject: AnyObject
    private let cgImage: CGImage
    private let runtimeGeneration: UUID
    private let selectedDeviceID: String?
    private let connectionGeneration: UUID

    init?(frame: ScreenFrame, runtimeGeneration: UUID, selectedDeviceID: String?, connectionGeneration: UUID) {
        guard let captureID = frame.captureID, frame.fullDisplay, !frame.jpeg.isEmpty,
              frame.width > 0, frame.height > 0, frame.sourceWidth > 0, frame.sourceHeight > 0,
              frame.capturedAt.timeIntervalSinceReferenceDate.isFinite,
              let cgImage = frame.image.cgImage, cgImage.width > 0, cgImage.height > 0 else { return nil }
        self.captureID = captureID; self.capturedAt = frame.capturedAt; self.jpeg = frame.jpeg
        self.width = frame.width; self.height = frame.height
        self.sourceWidth = frame.sourceWidth; self.sourceHeight = frame.sourceHeight
        self.imageObject = frame.image as AnyObject; self.cgImage = cgImage
        self.runtimeGeneration = runtimeGeneration; self.selectedDeviceID = selectedDeviceID
        self.connectionGeneration = connectionGeneration
    }

    func pixelFailures(_ current: ScreenFrame) -> [WorkflowLeaseFailure.Predicate] {
        let image = current.image.cgImage
        let checks: [(WorkflowLeaseFailure.Predicate, Bool)] = [
            (.currentCaptureMatches, current.captureID == captureID),
            (.currentPixelsMatch, current.capturedAt == capturedAt),
            (.currentFullDisplay, current.fullDisplay),
            (.currentDimensionsMatch, current.width == width && current.height == height &&
                image?.width == cgImage.width && image?.height == cgImage.height),
            (.currentSourceDimensionsMatch, current.sourceWidth == sourceWidth && current.sourceHeight == sourceHeight),
            (.currentImageObjectMatches, current.image as AnyObject === imageObject),
            (.currentCGImageObjectMatches, image === cgImage),
            (.currentJPEGMatches, current.jpeg == jpeg)
        ]
        return checks.filter { !$0.1 }.map(\.0)
    }

    func bindingFailures(runtimeGeneration: UUID, selectedDeviceID: String?, connectionGeneration: UUID) -> [WorkflowLeaseFailure.Predicate] {
        var failed: [WorkflowLeaseFailure.Predicate] = []
        if self.runtimeGeneration != runtimeGeneration { failed.append(.runtimeGenerationMatches) }
        if self.selectedDeviceID != selectedDeviceID { failed.append(.expectedAccessoryMatches) }
        if self.connectionGeneration != connectionGeneration { failed.append(.connectionGenerationMatches) }
        return failed
    }

    func matches(_ other: WorkflowObservationProof) -> Bool {
        bindingFailures(runtimeGeneration: other.runtimeGeneration, selectedDeviceID: other.selectedDeviceID,
            connectionGeneration: other.connectionGeneration).isEmpty && captureID == other.captureID && capturedAt == other.capturedAt &&
            width == other.width && height == other.height && sourceWidth == other.sourceWidth && sourceHeight == other.sourceHeight &&
            imageObject === other.imageObject && cgImage === other.cgImage && jpeg == other.jpeg
    }
}

@MainActor struct WorkflowObservationPair {
    let snapshot: PhoneUISnapshot
    let lease: WorkflowObservationLease
    var frame: ScreenFrame { lease.frame }
    var proof: WorkflowObservationProof { lease.proof }
    var connectionGeneration: UUID { lease.connectionGeneration }
}

/// Operation-local authority to use a *published* current confirmation for
/// exactly the original pixels. A cache hit cannot advance this lease.
@MainActor final class WorkflowObservationLease {
    typealias Current = @MainActor () -> WorkflowObservationState
    let proof: WorkflowObservationProof
    private let current: Current
    private let generation: UUID
    private let selectedDeviceID: String
    let connectionGeneration: UUID
    private let boundary: Date?
    private var floor: Date
    private(set) var frame: ScreenFrame

    convenience init(frame: ScreenFrame, after: Date, runtimeGeneration: UUID, selectedDeviceID: String?,
                     connectionGeneration: UUID, current: @escaping Current) throws {
        try self.init(frame: frame, boundary: after, runtimeGeneration: runtimeGeneration,
            selectedDeviceID: selectedDeviceID, connectionGeneration: connectionGeneration, current: current)
    }

    /// Read-only context creates no new input boundary. The caller's real
    /// confirmation is the initial floor; an Engine-proven strict input boundary
    /// remains inherited by every non-regressing actual current confirmation.
    static func contextFrame(_ frame: ScreenFrame, runtimeGeneration: UUID, selectedDeviceID: String?,
                             connectionGeneration: UUID, current: @escaping Current) throws -> WorkflowObservationLease {
        try WorkflowObservationLease(frame: frame, boundary: nil, runtimeGeneration: runtimeGeneration,
            selectedDeviceID: selectedDeviceID, connectionGeneration: connectionGeneration, current: current)
    }

    private init(frame: ScreenFrame, boundary: Date?, runtimeGeneration: UUID, selectedDeviceID: String?,
                 connectionGeneration: UUID, current: @escaping Current) throws {
        guard let proof = WorkflowObservationProof(frame: frame, runtimeGeneration: runtimeGeneration,
            selectedDeviceID: selectedDeviceID, connectionGeneration: connectionGeneration),
              boundary.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else {
            throw WorkflowLeaseFailure(predicates: [.sourcePixelsValid])
        }
        guard let selectedDeviceID, !selectedDeviceID.isEmpty else {
            throw WorkflowLeaseFailure(predicates: [.expectedAccessoryMatches])
        }
        self.proof = proof; self.current = current; self.generation = runtimeGeneration
        self.selectedDeviceID = selectedDeviceID; self.connectionGeneration = connectionGeneration
        self.boundary = boundary; self.floor = frame.confirmedAt; self.frame = frame
    }

    @discardableResult
    func advance(runtimeGeneration: UUID) throws -> ScreenFrame {
        try Task.checkCancellation()
        let state = current()
        var failed: [WorkflowLeaseFailure.Predicate] = []
        if !state.running { failed.append(.captureRunning) }
        if !state.accessoryReady { failed.append(.accessoryReady) }
        if state.selectedDeviceID != selectedDeviceID { failed.append(.expectedAccessoryMatches) }
        if state.connectionGeneration != connectionGeneration { failed.append(.connectionGenerationMatches) }
        if runtimeGeneration != generation { failed.append(.runtimeGenerationMatches) }
        guard let current = state.frame else {
            throw WorkflowLeaseFailure(predicates: failed + [.currentFramePresent])
        }
        failed += proof.pixelFailures(current)
        if !current.confirmedAt.timeIntervalSinceReferenceDate.isFinite { failed.append(.confirmationTimestampFinite) }
        if !(current.capturedAt <= current.confirmedAt) { failed.append(.pixelBeforeConfirmation) }
        if !(current.confirmedAt >= floor) { failed.append(.confirmationNotRegressed) }
        if let boundary, !(current.confirmedAt > boundary) { failed.append(.confirmationAfterBoundary) }
        // Check age *after* all byte/object comparisons. Their elapsed time
        // must not be hidden by a timestamp taken before the proof work.
        if !(0..<1.5).contains(Date().timeIntervalSince(current.confirmedAt)) { failed.append(.confirmationAgeValid) }
        try Task.checkCancellation()
        guard failed.isEmpty else { throw WorkflowLeaseFailure(predicates: failed) }
        floor = current.confirmedAt; frame = current
        return current
    }
}
