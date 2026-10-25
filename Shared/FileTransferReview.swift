import Foundation

/// The UI drafts a native human finding for an explicit subset. The coordinator
/// independently revalidates against the current persisted pending items.
struct FileTransferReviewRequest: Equatable {
    var operationID: String
    var artifactIDs: [UUID]
    var resolution: FileTransferHumanResolution
    var detail: String
    func validate(operation: FileTransferOperation) throws {
        guard operation.operationID == operationID, operation.pending,
              !artifactIDs.isEmpty, Set(artifactIDs).count == artifactIDs.count,
              Set(artifactIDs).isSubset(of:Set(operation.items.filter(\.pending).map(\.artifactID))),
              !detail.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, detail.count<=1000 else {
            throw FileTransferError.invalid("请选择当前仍待核验的原件，并填写逐项核验依据")
        }
    }
}
