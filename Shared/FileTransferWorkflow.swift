import Foundation
import CryptoKit

/// Identity and receipts for original-file sending. These are local-controller
/// contracts: model-written metadata is never evidence of an App selection.
enum FileTransferError: LocalizedError {
    case invalid(String), unavailable, pendingReview, unsupported(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let detail): return "文件发送参数或证据无效：" + detail
        case .unavailable: return "文件发送存储损坏或不可写；已停止，需先核验已有发送"
        case .pendingReview: return "已有文件提交待核验；只能只读核查，不能换任务、operation_id 或配件重发"
        case .unsupported(let detail): return "当前发送通道不支持可靠核验：" + detail
        }
    }
}

struct FileTransferArtifact: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var sourceID: String
    var filename: String
    var mediaType: String
    var byteCount: Int64
    var sha256: String
    var relativePath: String
    var importedAt: Date
    static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func digestFile(_ url: URL) throws -> (String, Int64) {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw FileTransferError.invalid("仅接受真实普通文件") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256(), count: Int64 = 0
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation(); hasher.update(data: bytes); count += Int64(bytes.count)
            guard count <= 2_147_483_648 else { throw FileTransferError.invalid("单文件超过 2 GiB") }
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }
    func validate() throws {
        guard !sourceID.isEmpty, sourceID.count <= 300, !filename.isEmpty, filename.count <= 240,
              filename != ".", filename != "..", !filename.contains("/"), !filename.contains("\\"),
              !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !mediaType.isEmpty, mediaType.count <= 200, (0...2_147_483_648).contains(byteCount),
              sha256.count == 64, sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              relativePath == id.uuidString + "/" + filename else { throw FileTransferError.invalid("文件 manifest") }
    }
}

struct FileTransferManifestItem: Codable, Equatable, Identifiable, Sendable {
    var artifact: FileTransferArtifact
    var ordinal: Int
    /// Original file bytes, never an implicitly compressed photo/video variant.
    var quality = "original_bytes"
    var id: UUID { artifact.id }
}

struct FileTransferRecipient: Codable, Equatable {
    enum Kind: String, Codable { case builtinSelfTransfer, userSelectedStableAccount, nativeShareRequestedUnverified }
    var kind: Kind
    var stableID: String
    var displayName: String
    /// Only a native, explicit user selection may create this authorization.
    /// It binds both the account and the requested original-file scope.
    var userSelectionEvidenceID: String?
    var authorizedArtifactIDs: [UUID]
    static func selfTransfer(artifactIDs: [UUID]) -> Self {
        Self(kind: .builtinSelfTransfer, stableID: "wechat:builtin:file-transfer-assistant",
             displayName: "文件传输助手", userSelectionEvidenceID: nil, authorizedArtifactIDs: artifactIDs)
    }
    func validate(artifactIDs: [UUID]) throws {
        guard !stableID.isEmpty, stableID.count <= 300, !displayName.isEmpty, displayName.count <= 120,
              authorizedArtifactIDs == artifactIDs, !artifactIDs.isEmpty else { throw FileTransferError.invalid("收件人或授权文件范围") }
        switch kind {
        case .builtinSelfTransfer:
            guard stableID == "wechat:builtin:file-transfer-assistant" else { throw FileTransferError.invalid("内置互传身份") }
        case .nativeShareRequestedUnverified:
            guard stableID == "native-share:unverified" else { throw FileTransferError.invalid("原生分享目标不能伪装为已核验身份") }
        case .userSelectedStableAccount:
            guard let evidence = userSelectionEvidenceID, !evidence.isEmpty, evidence.count <= 300,
                  stableID != "wechat:builtin:file-transfer-assistant" else { throw FileTransferError.invalid("普通联系人缺用户明确选定的稳定账号与授权范围") }
        }
    }
}

struct FileTransferEnvironment: Codable, Equatable {
    var deviceKey: String
    var accessoryKey: String
    var captureSessionID: String
    var foreground: Bool
    func validate() throws {
        guard !deviceKey.isEmpty, !accessoryKey.isEmpty, !captureSessionID.isEmpty, foreground else {
            throw FileTransferError.invalid("缺当前手机、配件、共享会话或前台状态")
        }
    }
}

struct FileTransferEvidenceContext: Codable, Equatable {
    var evidenceID: String
    var capturedAt: Date
    var environment: FileTransferEnvironment
    var confirmedAt: Date? = nil
    func validate(environment expected: FileTransferEnvironment, after: Date, now: Date = Date()) throws {
        try expected.validate()
        let confirmation = confirmedAt ?? capturedAt
        guard !evidenceID.isEmpty, evidenceID.count <= 300, environment == expected,
              capturedAt <= confirmation, confirmation >= after, confirmation <= now.addingTimeInterval(2), now.timeIntervalSince(confirmation) <= 1.5 else {
            throw FileTransferError.invalid("需要当前同一手机/配件/共享的新帧证据")
        }
    }
}

enum FileTransferIdentityLevel: String, Codable {
    case exactBytes, managedOriginalBytes, metadataOnly, unknown
}

struct FileTransferFileEvidence: Codable, Equatable {
    var artifactID: UUID
    var sourceID: String?
    var filename: String
    var mediaType: String?
    var byteCount: Int64?
    var sha256: String?
    var ordinal: Int
    var identityLevel: FileTransferIdentityLevel
    /// Managed original bytes are bound to an actual controller payload, never
    /// inferred from filename, size, a search row, or a share completion callback.
    var payloadBindingID: UUID?
    var originalBytesPreserved: Bool
    func validate(item: FileTransferManifestItem, bindingID: UUID) throws {
        let artifact = item.artifact
        guard artifactID == artifact.id, sourceID == artifact.sourceID, filename == artifact.filename,
              mediaType == artifact.mediaType, byteCount == artifact.byteCount, ordinal == item.ordinal,
              originalBytesPreserved else { throw FileTransferError.invalid("错文件、顺序或质量变化") }
        switch identityLevel {
        case .exactBytes:
            guard sha256 == artifact.sha256 else { throw FileTransferError.invalid("内容 SHA256 不一致") }
        case .managedOriginalBytes:
            guard payloadBindingID == bindingID, sha256 == artifact.sha256 else { throw FileTransferError.invalid("缺原始文件 payload 绑定") }
        case .metadataOnly, .unknown:
            throw FileTransferError.unsupported("文件名/大小不能证明文件内容；重名、相同大小或不可见 hash 均不猜测")
        }
    }
}

struct FileTransferRecipientEvidence: Codable, Equatable {
    enum Basis: String, Codable { case builtinTransferExplanation, stableAccountIdentifier, displayNameOnly, unknown }
    var stableID: String?
    var basis: Basis
    var conversationEvidenceID: String
    func validate(recipient: FileTransferRecipient) throws {
        let expected: Basis = recipient.kind == .builtinSelfTransfer ? .builtinTransferExplanation : .stableAccountIdentifier
        guard stableID == recipient.stableID, basis == expected, !conversationEvidenceID.isEmpty else {
            throw FileTransferError.unsupported("当前会话缺稳定收件人证据；显示名不能代替账号")
        }
    }
}

struct FileTransferLocatedFile: Equatable {
    var handle: String
    var identity: FileTransferFileEvidence
}

struct FileTransferPayload: Sendable {
    var bindingID: UUID
    var manifest: [FileTransferManifestItem]
    var fileURLs: [URL]
}

struct FileTransferSelectionEvidence: Codable, Equatable {
    var context: FileTransferEvidenceContext
    var recipient: FileTransferRecipientEvidence
    var files: [FileTransferFileEvidence]
    var selectedCount: Int
    var visibleEvidenceJSON: String? = nil
}

struct FileTransferDispatchReceipt: Equatable {
    enum Signal: String { case dispatched, shareExtensionCompleted, unknown }
    var signal: Signal
    var detail: String
    // No signal here is itself a send/delivery/read receipt.
}

struct FileTransferResultEvidence: Codable, Equatable {
    enum Status: String, Codable { case notSubmittedConfirmed, uploading, outgoingMessageObserved, confirmedNotSent, unknown }
    var context: FileTransferEvidenceContext
    var recipient: FileTransferRecipientEvidence
    var file: FileTransferFileEvidence
    var status: Status
    var messageID: String?
    var detail: String
    var visibleEvidenceJSON: String? = nil
}

struct FileTransferItemProgress: Codable, Equatable, Identifiable {
    enum State: String, Codable { case notSubmitted, submissionPending, uploading, observedSent, userReportedSubmitted, confirmedFailed, unknown }
    var artifactID: UUID
    var state: State = .notSubmitted
    var attemptCount = 0
    var submittedAt: Date?
    var messageID: String?
    var evidence: FileTransferResultEvidence?
    var id: UUID { artifactID }
    var pending: Bool { [.submissionPending, .uploading, .unknown].contains(state) }
}

struct FileTransferOperation: Codable, Equatable, Identifiable {
    enum Stage: String, Codable { case prepared, locating, selecting, selectionVerified, submissionPending, uploading, complete, partial, pendingReview, cancelled, unsupported }
    var operationID: String
    var taskID: String
    var recipient: FileTransferRecipient
    var manifest: [FileTransferManifestItem]
    var environment: FileTransferEnvironment
    var payloadBindingID: UUID
    var stage: Stage = .prepared
    var items: [FileTransferItemProgress]
    var createdAt: Date
    var updatedAt: Date
    var lastSelection: FileTransferSelectionEvidence?
    var cancelled = false
    var humanReviews: [FileTransferHumanReview]? = nil
    var detail = "尚未提交"
    var id: String { operationID }
    var pending: Bool { items.contains(where: \.pending) }
    var observedSentCount: Int { items.filter { $0.state == .observedSent }.count }
    /// This receipt intentionally has no delivered/read property.
    var verificationScope: String { "observed_app_submission_only_not_recipient_delivery_or_read" }
    var retryableArtifactIDs: [UUID] { items.filter { $0.state == .notSubmitted || $0.state == .confirmedFailed }.map(\.artifactID) }
    func validate() throws {
        guard (8...96).contains(operationID.count), operationID.allSatisfy({ "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.".contains($0) }),
              !taskID.isEmpty, taskID.count <= 300, !manifest.isEmpty, manifest.count <= 50,
              Set(manifest.map(\.id)).count == manifest.count,
              Set(manifest.map { $0.artifact.sourceID }).count == manifest.count,
              manifest.map(\.ordinal) == Array(manifest.indices), items.map(\.artifactID) == manifest.map(\.id),
              items.allSatisfy({ $0.attemptCount >= 0 && (!$0.pending || $0.submittedAt != nil) }),
              detail.count <= 2000 else { throw FileTransferError.invalid("发送检查点") }
        try environment.validate(); try recipient.validate(artifactIDs: manifest.map(\.id))
        for item in manifest { try item.artifact.validate(); guard item.quality == "original_bytes" else { throw FileTransferError.invalid("文件质量") } }
        let reviews = humanReviews ?? []
        guard reviews.count <= 500, Set(reviews.map(\.id)).count == reviews.count else { throw FileTransferError.invalid("人工核验历史数量或标识") }
        for review in reviews {
            guard !review.artifactIDs.isEmpty, review.artifactIDs.count <= manifest.count,
                  Set(review.artifactIDs).count == review.artifactIDs.count,
                  Set(review.artifactIDs).isSubset(of: Set(manifest.map(\.id))),
                  !review.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, review.detail.count <= 1000,
                  review.reviewedAt.timeIntervalSince1970.isFinite,
                  review.reviewedAt >= createdAt, review.reviewedAt <= updatedAt else { throw FileTransferError.invalid("人工核验历史范围、文字或时间") }
        }
    }
}

/// Only trusted native bridges implement this protocol. Snapshot IDs, stable
/// account IDs and SHA256 values must come from real UI/local payload state.
/// locate/select may navigate and select, but MUST NOT dispatch or present a
/// share extension capable of sending. submit is the sole side-effect boundary.
@MainActor protocol FileTransferDriving {
    func locate(payload: FileTransferPayload, recipient: FileTransferRecipient, environment: FileTransferEnvironment) async throws -> [FileTransferLocatedFile]
    func select(files: [FileTransferLocatedFile], payload: FileTransferPayload, recipient: FileTransferRecipient, environment: FileTransferEnvironment) async throws
    func observeSelection(payload: FileTransferPayload, recipient: FileTransferRecipient, environment: FileTransferEnvironment, after: Date) async throws -> FileTransferSelectionEvidence
    func submit(payload: FileTransferPayload, recipient: FileTransferRecipient, selection: FileTransferSelectionEvidence, environment: FileTransferEnvironment) async throws -> FileTransferDispatchReceipt
    /// Read-only, bounded inspection. Must not input, resend or change selection.
    func inspect(operation: FileTransferOperation, environment: FileTransferEnvironment, after: Date) async throws -> [FileTransferResultEvidence]
}

/// UIActivityViewController completion is only an extension callback. The host
/// must use dismissedOrUnknown for completed=false unless it independently
/// proves no submission ever occurred.
enum FileTransferNativeShareResult {
    case extensionCompleted(activityType: String?)
    case dismissedOrUnknown
    case confirmedNotSubmitted(evidenceID: String)
}

enum FileTransferHumanResolution: String, Codable {
    case userReportsSubmitted, userConfirmsNotSubmitted, stillUnknown
}

/// Native original selection is known before presentation, recipient authority
/// is established only INSIDE the current extension confirmation screen.
struct FileTransferAutomaticSubmission {
    var selection: FileTransferSelectionEvidence
    var dispatch: FileTransferDispatchReceipt
}

@MainActor protocol FileTransferAutomaticNativeDriving: FileTransferDriving {
    /// The coordinator has durably crossed submissionPending before invoking.
    /// A host may present a real extension here; no other protocol phase may.
    func presentAndSubmit(payload: FileTransferPayload, recipient: FileTransferRecipient,
                          environment: FileTransferEnvironment,
                          confirmSelection: @MainActor (FileTransferSelectionEvidence) throws -> Void) async throws -> FileTransferAutomaticSubmission
}

/// Append-only human findings; optional on operations for Build 74 migration.
struct FileTransferHumanReview: Codable, Equatable, Identifiable {
    var id: UUID
    var artifactIDs: [UUID]
    var resolution: FileTransferHumanResolution
    var detail: String
    var reviewedAt: Date
}

struct FileTransferLibraryArchive: Codable, Equatable, Identifiable {
    var artifactID: UUID
    var archivedAt: Date
    var id: UUID { artifactID }
}

struct FileTransferLibraryItem: Identifiable {
    var artifact: FileTransferArtifact
    var archivedAt: Date?
    /// Expected content grouping from immutable import manifests, NOT a claim
    /// about current inode sharing or allocated disk space.
    var sameContentSourceCount: Int
    var receiptOperationIDs: [String]
    var referencedBySavedPlan: Bool
    var deletionBlockReason: String?
    var id: UUID { artifact.id }
    var isArchived: Bool { archivedAt != nil }
    var canDelete: Bool { deletionBlockReason == nil }
}

struct FileTransferStorageStatistics: Codable, Equatable, Sendable {
    var artifactCount: Int
    var activeArtifactCount: Int
    var archivedArtifactCount: Int
    var manifestBytes: Int64
    /// Byte lengths measured at each existing path, counting hard-link aliases.
    var actualPathBytes: Int64
    /// Actual file lengths grouped by filesystem device+inode. nil if any
    /// source is unavailable/corrupt or a stable inode cannot be established.
    var uniqueStoredFileBytes: Int64?
    /// Filesystem-reported allocation grouped by device+inode; optional because
    /// providers/filesystems may not expose it. Not total app/container usage.
    var allocatedStoredBytes: Int64?
    var hardLinkSavingsBytes: Int64?
    var unavailableArtifactIDs: [UUID]
    var corruptArtifactIDs: [UUID]
    var verifiedAt: Date
    var complete: Bool { unavailableArtifactIDs.isEmpty && corruptArtifactIDs.isEmpty && uniqueStoredFileBytes != nil }
}
