import Foundation

/// The host must still approve the original recipient/model/memory snapshot
/// before a response can become a preparation patch, not only before rendering.
@MainActor enum PaotuiInterpretationGate {
    enum ApprovalError: LocalizedError {
        case changed
        var errorDescription: String? { "模型或记忆设置已改变，本次解释未采用，请重新发送" }
    }
    static func run(operation: () async throws -> String, isApproved: () -> Bool) async throws -> String {
        try Task.checkCancellation()
        guard isApproved() else { throw ApprovalError.changed }
        let result = try await operation()
        try Task.checkCancellation()
        guard isApproved() else { throw ApprovalError.changed }
        return result
    }
}
