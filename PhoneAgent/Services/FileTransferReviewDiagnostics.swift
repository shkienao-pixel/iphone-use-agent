import Foundation

/// Reconcile from durable human findings. No UI flag, export success, arbitrary
/// record ID or restart alone may clear protection for an uncertain submission.
@MainActor enum FileTransferReviewDiagnostics {
    @discardableResult static func reconcile(fileStore:FileTransferStore,diagnostics:WorkflowDiagnosticsStore) throws -> Int {
        let ids=Set(diagnostics.records.filter(\.isProtectedPendingSubmission).compactMap(\.context.operationID))
        var released=0
        for id in ids {
            guard let operation=try fileStore.operation(id:id),!operation.pending,
                  operation.humanReviews?.contains(where:{$0.resolution != .stillUnknown}) == true else {continue}
            released += try diagnostics.releaseProtection(operationID:id,reviewNote:"本批全部待核验原件已由用户逐项独立检查；依据持久化回执解除诊断保留保护，不触发发送")
        }
        return released
    }
}
