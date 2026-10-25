import Foundation

/// A false UIKit AssistiveTouch query is conclusive only while Guided Access
/// is enabled (UIKit's documented query limitation). Unknown never means off.
enum AssistiveTouchObservedState: Equatable, Sendable {
    case enabled, disabled, unknown
    var allowsStartup: Bool { self != .disabled }
    static func observed(reportedRunning: Bool, guidedAccessEnabled: Bool) -> Self {
        if reportedRunning { return .enabled }
        return guidedAccessEnabled ? .disabled : .unknown
    }
}

/// Actual owner observations, not settings, screen labels or model output.
/// Missing observations may be acquired only under the current preparation.
struct AssistiveTouchVerificationContext: Equatable, Sendable {
    var preparationID: UUID?
    var accessoryID: String?
    var connectionID: UUID?
    var calibrationFingerprint: Data?
    var captureID: UUID?
    var captureRunning: Bool

    fileprivate var valid: Bool {
        (accessoryID.map { !$0.isEmpty } ?? true) &&
        (connectionID == nil || accessoryID != nil) &&
        (calibrationFingerprint.map { !$0.isEmpty && connectionID != nil } ?? true) &&
        (captureID == nil || captureRunning)
    }
    fileprivate var fullyBound: Bool {
        accessoryID != nil && connectionID != nil && calibrationFingerprint != nil && captureID != nil && captureRunning
    }
}

/// Process-local, non-Codable user evidence. This never certifies BLE, pointer
/// calibration, capture freshness, target identity or an input result. Existing
/// owners must still independently enforce all those conditions.
struct AssistiveTouchSessionVerification: Sendable {
    private var confirmation: AssistiveTouchVerificationContext?

    mutating func invalidate() { confirmation = nil }

    @discardableResult
    mutating func confirm(observation: AssistiveTouchObservedState,
                          context: AssistiveTouchVerificationContext) -> Bool {
        guard observation == .unknown, context.valid, context.preparationID != nil else {
            invalidate(); return false
        }
        confirmation = context
        return true
    }

    mutating func isReady(observation: AssistiveTouchObservedState,
                          context: AssistiveTouchVerificationContext) -> Bool {
        if observation == .enabled { invalidate(); return true }
        guard observation == .unknown, context.valid, var bound = confirmation else {
            invalidate(); return false
        }
        // Once observed, a bound object may never silently migrate, disappear,
        // or be replaced, including by a newly prepared connection/stream.
        if let accessory = bound.accessoryID, context.accessoryID != accessory { invalidate(); return false }
        if let connection = bound.connectionID, context.connectionID != connection { invalidate(); return false }
        if let calibration = bound.calibrationFingerprint, context.calibrationFingerprint != calibration { invalidate(); return false }
        if let capture = bound.captureID {
            guard context.captureRunning else { invalidate(); return false }
            if let current = context.captureID, current != capture { invalidate(); return false }
        }
        if !bound.fullyBound {
            guard let authorization = bound.preparationID, context.preparationID == authorization else {
                invalidate(); return false
            }
            // The native confirmation explicitly covers the following normal
            // connection/calibration/first-capture steps of THIS preparation.
            if bound.accessoryID == nil { bound.accessoryID = context.accessoryID }
            if bound.connectionID == nil { bound.connectionID = context.connectionID }
            if bound.calibrationFingerprint == nil { bound.calibrationFingerprint = context.calibrationFingerprint }
            if bound.captureID == nil, context.captureRunning, context.captureID != nil {
                bound.captureID = context.captureID; bound.captureRunning = true
            }
            confirmation = bound
            return true // Only this requirement; other snapshot requirements still apply.
        }
        // An established control session survives ordinary app switching and
        // pause/continue only on the same actual accessory/calibration/stream.
        return context.fullyBound && context.captureID == bound.captureID
    }
}

/// The next missing requirement, based only on the caller's observed state.
enum AutomaticPreparationStep: Hashable, Sendable {
    case model
    case consent
    case systemTools
    case assistiveTouch
    case device
    case calibration
    case screen
    case ready
}

/// Saved setup used only to decide whether to show the home configuration card.
/// This does not certify a live connection, AssistiveTouch, a current screen,
/// or permission to execute. AutomaticPreparationSnapshot owns those checks.
struct SavedPreparationConfiguration: Sendable {
    let modelReady: Bool
    let consentReady: Bool
    let toolsOnly: Bool
    let systemToolsEnabled: Bool
    let previewOnly: Bool
    let accessoryConfigured: Bool
    let calibrationConfigured: Bool

    var configurationStep: AutomaticPreparationStep {
        guard modelReady else { return .model }
        guard consentReady else { return .consent }
        if toolsOnly {
            return systemToolsEnabled ? .ready : .systemTools
        }
        if !previewOnly {
            guard accessoryConfigured else { return .device }
            guard calibrationConfigured else { return .calibration }
        }
        return .ready
    }

    var configured: Bool { configurationStep == .ready }
}

/// A snapshot never grants permissions, reconnects devices, or certifies a
/// calibration. Those operations must update their owning sources first.
struct AutomaticPreparationSnapshot: Sendable {
    let modelReady: Bool
    let consentReady: Bool
    let toolsOnly: Bool
    let systemToolsEnabled: Bool
    let previewOnly: Bool
    let assistiveTouchReady: Bool
    let deviceReady: Bool
    let calibrationReady: Bool
    let fullScreenReady: Bool

    var nextStep: AutomaticPreparationStep {
        guard modelReady else { return .model }
        guard consentReady else { return .consent }
        if toolsOnly {
            return systemToolsEnabled ? .ready : .systemTools
        }
        if !previewOnly {
            guard assistiveTouchReady else { return .assistiveTouch }
            guard deviceReady else { return .device }
            guard calibrationReady else { return .calibration }
        }
        guard fullScreenReady else { return .screen }
        return .ready
    }
}
