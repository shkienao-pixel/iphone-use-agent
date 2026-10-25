import Foundation
import CryptoKit

enum WorkflowDiagnosticBoundary: String, Codable, CaseIterable {
    case observed, beforeInput, afterInput, paused, failed, completed, pendingSubmission
    var retentionPriority: Int {
        switch self {
        case .observed: return 0
        case .completed: return 1
        case .beforeInput, .afterInput: return 2
        case .paused, .failed: return 3
        case .pendingSubmission: return 4
        }
    }
}

struct WorkflowDiagnosticContext: Codable, Equatable {
    var workflowID: String?
    var operationID: String?
    var boundary: WorkflowDiagnosticBoundary
    var captureID: UUID
    /// Real pixel timestamp and system confirmation timestamp remain distinct.
    var capturedAt: Date
    var confirmedAt: Date
    var snapshot: PhoneUISnapshot
    var action: String?
    var reason: String?
    var result: String?
    var protectPendingSubmission: Bool

    init(workflowID: String? = nil, operationID: String? = nil, boundary: WorkflowDiagnosticBoundary,
         captureID: UUID, capturedAt: Date, confirmedAt: Date, snapshot: PhoneUISnapshot,
         action: String? = nil, reason: String? = nil, result: String? = nil, protectPendingSubmission: Bool = false) {
        self.workflowID = workflowID; self.operationID = operationID; self.boundary = boundary
        self.captureID = captureID; self.capturedAt = capturedAt; self.confirmedAt = confirmedAt; self.snapshot = snapshot
        self.action = action; self.reason = reason; self.result = result; self.protectPendingSubmission = protectPendingSubmission
    }
    func validate() throws {
        func identifier(_ value: String?) -> Bool {
            guard let value else { return true }
            return !value.isEmpty && value.count <= 160 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        guard identifier(workflowID), identifier(operationID),
              capturedAt.timeIntervalSince1970.isFinite, confirmedAt.timeIntervalSince1970.isFinite,
              capturedAt <= confirmedAt, snapshot.capturedAt == capturedAt,
              !snapshot.deviceKey.isEmpty, snapshot.deviceKey.count <= 1200,
              !snapshot.scene.isEmpty, snapshot.scene.count <= 120,
              snapshot.elements.count <= 4000, Set(snapshot.elements.map(\.id)).count == snapshot.elements.count,
              snapshot.elements.allSatisfy({ $0.rect.valid && !$0.id.isEmpty && $0.id.count <= 400 && $0.source.count <= 64 }),
              snapshot.elements.reduce(0, { $0 + $1.label.utf8.count }) <= 500_000,
              [action, reason, result].allSatisfy({ $0.map { $0.count <= 3000 } ?? true }),
              !(protectPendingSubmission || boundary == .pendingSubmission) || operationID != nil else {
            throw WorkflowDiagnosticsError.invalidContext
        }
    }
}

struct WorkflowDiagnosticsPolicy: Equatable {
    var maximumRecords = 250
    var maximumImages = 120
    var maximumImageBytes = 80 * 1024 * 1024
    var maximumSingleImageBytes = 4 * 1024 * 1024
    var maximumIndexBytes = 8 * 1024 * 1024
    var maximumExportBytes = 128 * 1024 * 1024
    var maximumExports = 3
    var maximumStoredExportBytes = 256 * 1024 * 1024
    static let `default` = Self()
    func validate() throws {
        guard (1...5000).contains(maximumRecords), (0...2000).contains(maximumImages),
              (0...1024 * 1024 * 1024).contains(maximumImageBytes),
              (1...20 * 1024 * 1024).contains(maximumSingleImageBytes),
              (1024...64 * 1024 * 1024).contains(maximumIndexBytes),
              (1024...512 * 1024 * 1024).contains(maximumExportBytes), (1...10).contains(maximumExports),
              maximumStoredExportBytes >= maximumExportBytes, maximumStoredExportBytes <= 1024 * 1024 * 1024 else {
            throw WorkflowDiagnosticsError.invalidPolicy
        }
    }
}

enum WorkflowDiagnosticImageStatus: String, Codable {
    case stored, noImageSupplied, notStoredInvalidJPEG, notStoredOversize, notStoredNoSpace, notStoredWriteFailure, removedByRetention
}

struct WorkflowDiagnosticRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var context: WorkflowDiagnosticContext
    var recordedAt: Date
    var originalSHA256: String
    var originalByteCount: Int
    var imageStatus: WorkflowDiagnosticImageStatus
    var imageFilename: String?
    var jpegWidth: Int?
    var jpegHeight: Int?
    var isProtectedPendingSubmission: Bool
    var protectionReleasedAt: Date?
    var protectionReviewNote: String?
    var imageStored: Bool { imageStatus == .stored }
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validSHA256(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    func validate() throws {
        try context.validate()
        let originallyProtected = context.protectPendingSubmission || context.boundary == .pendingSubmission
        guard recordedAt.timeIntervalSince1970.isFinite, recordedAt.timeIntervalSince(context.confirmedAt) >= -1,
              Self.validSHA256(originalSHA256), originalByteCount >= 0,
              !isProtectedPendingSubmission || (originallyProtected && context.operationID != nil),
              !originallyProtected || isProtectedPendingSubmission || (protectionReleasedAt != nil && protectionReviewNote?.isEmpty == false),
              protectionReleasedAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= recordedAt }) ?? true,
              protectionReviewNote.map({ !$0.isEmpty && $0.count <= 1000 }) ?? true else {
            throw WorkflowDiagnosticsError.invalidArchive
        }
        if imageStored {
            guard imageFilename == id.uuidString.lowercased() + ".jpg", originalByteCount > 0,
                  let jpegWidth, let jpegHeight, jpegWidth > 0, jpegHeight > 0 else { throw WorkflowDiagnosticsError.invalidArchive }
        } else if imageFilename != nil { throw WorkflowDiagnosticsError.invalidArchive }
        if imageStatus == .noImageSupplied, originalByteCount != 0 { throw WorkflowDiagnosticsError.invalidArchive }
    }
}

struct WorkflowDiagnosticsExport: Equatable {
    var url: URL
    var recordCount: Int
    var imageCount: Int
    var byteCount: Int
}

struct WorkflowDiagnosticsCleanup: Equatable {
    var removedRecords: Int
    var removedImages: Int
    var retainedProtectedRecords: Int
    var removedExports = 0
}

/// JSON export contains the ORIGINAL JPEG bytes, not just paths or checksums.
struct WorkflowDiagnosticsBundle: Codable {
    struct Entry: Codable { var record: WorkflowDiagnosticRecord; var jpeg: Data? }
    var version: Int
    var createdAt: Date
    var notice: String
    var entries: [Entry]
}

enum WorkflowDiagnosticsError: LocalizedError, Equatable {
    case invalidContext, invalidPolicy, invalidArchive, unsafePath, unavailable, capacity, imageUnavailable, exportTooLarge, invalidSelection
    var errorDescription: String? {
        switch self {
        case .invalidContext: return "诊断上下文无效，本次诊断未记录"
        case .invalidPolicy: return "诊断存储上限无效，本次诊断未记录"
        case .invalidArchive: return "诊断索引或截图校验失败；原数据已保留，禁止覆盖"
        case .unsafePath: return "诊断路径包含软链、越界文件或已被替换；本次诊断未记录"
        case .unavailable: return "诊断存储不可用，本次诊断未记录；原有证据已保留"
        case .capacity: return "诊断容量已满且现有证据不能自动删除；本次诊断未记录，请先处理已核验记录"
        case .imageUnavailable: return "此条诊断没有已保存的原图；不能将元数据宣称为已存截图"
        case .exportTooLarge: return "诊断包超过本机导出上限；没有生成不完整的分享文件，请减少所选记录"
        case .invalidSelection: return "诊断记录选择不存在、重复或为空"
        }
    }
}
