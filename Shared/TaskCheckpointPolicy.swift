import Foundation

// Non-authoritative observation from the existing open_search recognition only.
enum TaskCheckpointSource: Equatable { case alreadyVisible, afterInput }
enum TaskCheckpointVerificationScope: Equatable {
    // Existing classifier recognizes a search-like scene, not system ownership.
    case searchSceneOnly
    // Reserved for an independently verified system identity; the current
    // open_search recognizer does not produce this scope.
    case systemSearchVerified
}
struct TaskCheckpointFact {
    let scene: String
    let source: TaskCheckpointSource
    let verificationScope: TaskCheckpointVerificationScope
    let captureID: UUID?
    let capturedAt: Date
    let confirmedAt: Date
    let inputCompletedAt: Date?
    let fullDisplay: Bool
    let blockingOverlay: Bool
    let selectedDeviceID: String?
    let connectionGeneration: UUID
    let runtimeGeneration: UUID
}

// Bound by the host at the time of receipt, never by model-supplied text.
struct TaskCheckpointBinding: Equatable {
    let taskID: UUID
    let sessionID: UUID
    let goalDigest: String
    let selectedDeviceID: String?
    let connectionGeneration: UUID
    let runtimeGeneration: UUID
}
enum TaskCheckpointCondition { case systemSearchVisible }
enum TaskCheckpointVerdict: String { case pass, fail, unknown }
struct TaskCheckpointDecision {
    let verdict: TaskCheckpointVerdict
    let reason: String
    let evidenceReference: String?
}
struct TaskCheckpointCurrent {
    let binding: TaskCheckpointBinding
    // The caller must check the actual capture state and exact current pixels,
    // dimensions, orientation and confirmation, using existing validity rules.
    // nil denotes unavailable evidence, not success.
    let runActive: Bool?
    let captureRunning: Bool?
    let accessoryReady: Bool?
    let currentFrameMatches: Bool?
    let pendingReview: Bool?
}
enum TaskCheckpointPolicy {
    static func evaluate(condition: TaskCheckpointCondition?, fact: TaskCheckpointFact?,
                         binding: TaskCheckpointBinding?, current: TaskCheckpointCurrent?) -> TaskCheckpointDecision {
        func result(_ verdict: TaskCheckpointVerdict, _ reason: String, _ ref: String? = nil) -> TaskCheckpointDecision {
            .init(verdict: verdict, reason: reason, evidenceReference: ref)
        }
        guard condition != nil else { return result(.unknown, "condition_missing") }
        guard let fact, let binding, let current else { return result(.unknown, "evidence_missing") }
        guard !binding.goalDigest.isEmpty, let accessory = binding.selectedDeviceID, !accessory.isEmpty,
              let frameID = fact.captureID else { return result(.unknown, "binding_incomplete") }
        guard binding == current.binding, fact.selectedDeviceID == binding.selectedDeviceID,
              fact.connectionGeneration == binding.connectionGeneration,
              fact.runtimeGeneration == binding.runtimeGeneration else { return result(.unknown, "binding_changed") }
        guard current.runActive == true else { return result(.unknown, "run_inactive") }
        guard current.captureRunning == true, current.accessoryReady == true,
              current.currentFrameMatches == true else { return result(.unknown, "observation_invalid") }
        guard current.pendingReview == false else { return result(.unknown, "pending_or_unknown") }
        let captured = fact.capturedAt.timeIntervalSinceReferenceDate
        let confirmed = fact.confirmedAt.timeIntervalSinceReferenceDate
        guard captured.isFinite, confirmed.isFinite, captured <= confirmed, fact.fullDisplay,
              !fact.blockingOverlay else { return result(.unknown, "observation_incomplete") }
        switch fact.source {
        case .alreadyVisible:
            guard fact.inputCompletedAt == nil else { return result(.unknown, "unexpected_input_boundary") }
        case .afterInput:
            guard let boundary = fact.inputCompletedAt?.timeIntervalSinceReferenceDate,
                  boundary.isFinite, captured > boundary, confirmed > boundary else {
                return result(.unknown, "post_input_observation_unproven")
            }
        }
        let ref = "capture:" + frameID.uuidString + "/pixel-time:" + String(captured.bitPattern, radix: 16)
        guard !fact.scene.isEmpty, fact.scene != "unknown" else { return result(.unknown, "scene_unknown", ref) }
        guard fact.scene == "search" else { return result(.fail, "wrong_scene", ref) }
        guard fact.verificationScope == .systemSearchVerified else {
            return result(.unknown, "system_identity_unverified", ref)
        }
        return result(.pass, "system_search_visible", ref)
    }
}
