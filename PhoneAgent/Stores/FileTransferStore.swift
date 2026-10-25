import Foundation
#if canImport(Combine)
import Combine
#endif

/// Native I/O seam used by storage-failure fixtures. Production always uses
/// real atomic writes and same-container moves; no user originals are removed.
@MainActor struct FileTransferLibraryIO {
    var write: @MainActor (Data, URL) throws -> Void
    var move: @MainActor (URL, URL) throws -> Void
    var remove: @MainActor (URL) throws -> Void
    var link: @Sendable (URL, URL) throws -> Void = { try FileManager.default.linkItem(at: $0, to: $1) }
    static var system: Self {
        Self(write: { data, url in
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
        }, move: { try FileManager.default.moveItem(at: $0, to: $1) }, remove: { try FileManager.default.removeItem(at: $0) })
    }
}

/// Original import manifests remain immutable. Content-identical sources keep
/// separate IDs/names/provenance and may share verified bytes through hard links.
@MainActor final class FileTransferStore: ObservableObject {
    static let shared = FileTransferStore()
    @Published private(set) var artifacts: [FileTransferArtifact] = []
    @Published private(set) var operations: [FileTransferOperation] = []
    @Published private(set) var archives: [FileTransferLibraryArchive] = []
    @Published private(set) var error = ""
    private(set) var readable = true
    private var activeOperationID: String?
    private var importing = false
    private var importWaiters: [CheckedContinuation<Void, Never>] = []
    private var statisticsReaders = 0
    private let libraryIO: FileTransferLibraryIO
    let url: URL
    private var filesRoot: URL { url.deletingLastPathComponent().appendingPathComponent("original-files", isDirectory: true) }
    private var trashRoot: URL { url.deletingLastPathComponent().appendingPathComponent("file-library-trash", isDirectory: true) }
    private var deletionURL: URL { url.appendingPathExtension("deletion.json") }
    private struct Library: Codable { var version = 1; var archives: [FileTransferLibraryArchive] }
    private struct Document: Codable {
        var version = 1
        var artifacts: [FileTransferArtifact]
        var operations: [FileTransferOperation]
        var library: Library? = nil // Missing on Build 74; manifests are unchanged.
    }
    private struct DeletionIntent: Codable {
        var version = 1
        var id: UUID
        var artifact: FileTransferArtifact
    }
    private enum Recovery { case rolledBack, committed }
    private struct Imported: Sendable { var artifact: FileTransferArtifact; var created: Bool }
    var hasPendingReview: Bool { !readable || operations.contains(where: \.pending) }
    var pendingOperations: [FileTransferOperation] { operations.filter(\.pending) }
    var hasActiveOperation: Bool { activeOperationID != nil }

    init(url: URL? = nil, libraryIO: FileTransferLibraryIO? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneAgent/file-transfer/checkpoints.json")
        self.libraryIO = libraryIO ?? .system
        guard FileManager.default.fileExists(atPath: self.url.path) else {
            if FileManager.default.fileExists(atPath: deletionURL.path) { readable = false; error = FileTransferError.unavailable.localizedDescription }
            return
        }
        do {
            let document = try readDocument(); adopt(document)
            if FileManager.default.fileExists(atPath: deletionURL.path) { _ = try recoverDeletion() }
            var restored = operations, changed = false
            for index in restored.indices where restored[index].pending {
                for item in restored[index].items.indices where [.submissionPending, .uploading].contains(restored[index].items[item].state) {
                    restored[index].items[item].state = .unknown; changed = true
                }
                restored[index].stage = .pendingReview
                restored[index].detail = "进程重启后仅保留待核验；不得重放发送、分享或选择"
            }
            if changed { try save(artifacts: artifacts, operations: restored) } else { operations = restored }
        } catch { readable = false; self.error = FileTransferError.unavailable.localizedDescription }
    }
    func claim(operationID: String) throws {
        guard readable else { throw FileTransferError.unavailable }
        guard activeOperationID == nil else { throw FileTransferError.pendingReview }
        activeOperationID = operationID
    }
    func release(operationID: String) { if activeOperationID == operationID { activeOperationID = nil } }

    @discardableResult func importFile(at sourceURL: URL, sourceID: String, mediaType: String) throws -> FileTransferArtifact {
        guard readable, !importing else { throw FileTransferError.unavailable }
        importing = true; defer { releaseImport() }
        let result = try Self.copyOriginal(at: sourceURL, sourceID: sourceID, mediaType: mediaType, root: filesRoot, candidates: artifacts, link: libraryIO.link)
        return try commitImport(result)
    }
    /// All large I/O is off the UI actor. Concurrent async imports serialize so
    /// source-ID idempotency and actual byte reuse use the latest committed set.
    @discardableResult func importFileAsync(at sourceURL: URL, sourceID: String, mediaType: String) async throws -> FileTransferArtifact {
        if importing { await withCheckedContinuation { importWaiters.append($0) } } else { importing = true }
        defer { releaseImport() }
        guard readable else { throw FileTransferError.unavailable }
        try Task.checkCancellation()
        let root = filesRoot, candidates = artifacts, link = libraryIO.link
        let worker = Task.detached { try Self.copyOriginal(at: sourceURL, sourceID: sourceID, mediaType: mediaType, root: root, candidates: candidates, link: link) }
        let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        do { try Task.checkCancellation() }
        catch { if result.created { try? FileManager.default.removeItem(at: root.appendingPathComponent(result.artifact.id.uuidString)) }; throw error }
        return try commitImport(result)
    }
    private func releaseImport() {
        if importWaiters.isEmpty { importing = false }
        else { importWaiters.removeFirst().resume() }
    }
    private func commitImport(_ result: Imported) throws -> FileTransferArtifact {
        if !result.created { return result.artifact }
        do { try save(artifacts: artifacts + [result.artifact], operations: operations); return result.artifact }
        catch {
            // An atomic writer may throw after committing (e.g. a protection
            // attribute failure). Never remove bytes retained by durable metadata.
            if let durable = try? readDocument() {
                adopt(durable)
                if durable.artifacts.contains(result.artifact) { readable = true; self.error = ""; return result.artifact }
                try? FileManager.default.removeItem(at: filesRoot.appendingPathComponent(result.artifact.id.uuidString))
                readable = true
            } else if !FileManager.default.fileExists(atPath: url.path), artifacts.isEmpty, operations.isEmpty, archives.isEmpty {
                // Failed first-ever metadata write: no durable record can refer
                // to this private staging folder, so discard only that folder.
                try? FileManager.default.removeItem(at: filesRoot.appendingPathComponent(result.artifact.id.uuidString))
                readable = true
            }
            throw error
        }
    }
    private nonisolated static func copyOriginal(at sourceURL: URL, sourceID: String, mediaType: String, root: URL,
                                                 candidates: [FileTransferArtifact], link: @Sendable (URL, URL) throws -> Void) throws -> Imported {
        let id = UUID(), filename = sourceURL.lastPathComponent
        var artifact = FileTransferArtifact(id: id, sourceID: sourceID, filename: filename, mediaType: mediaType, byteCount: 0,
            sha256: String(repeating: "0", count: 64), relativePath: id.uuidString + "/" + filename, importedAt: Date())
        try artifact.validate(); try Task.checkCancellation()
        let original = try FileTransferArtifact.digestFile(sourceURL)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try validateDirectory(root)
        if let sameSource = candidates.first(where: { $0.sourceID == sourceID }) {
            try validateDirectory(root.appendingPathComponent(sameSource.id.uuidString))
            guard sameSource.filename == filename, sameSource.mediaType == mediaType,
                  sameSource.sha256 == original.0, sameSource.byteCount == original.1,
                  try FileTransferArtifact.digestFile(root.appendingPathComponent(sameSource.relativePath)) == original else {
                throw FileTransferError.invalid("sourceID 已绑定不同名称、类型、内容或已损坏原件；未覆盖旧来源")
            }
            return .init(artifact: sameSource, created: false)
        }
        artifact.sha256 = original.0; artifact.byteCount = original.1
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let destination = folder.appendingPathComponent(filename)
            var linked = false
            for candidate in candidates where candidate.sha256 == original.0 && candidate.byteCount == original.1 {
                try Task.checkCancellation()
                let existing = root.appendingPathComponent(candidate.relativePath)
                // Never trust a matching manifest without reading actual bytes.
                let actual: (String, Int64)
                do {
                    try validateDirectory(existing.deletingLastPathComponent())
                    actual = try FileTransferArtifact.digestFile(existing)
                } catch is CancellationError { throw CancellationError() }
                catch { continue }
                guard actual == original else { continue }
                do { try link(existing, destination); linked = true; break }
                catch is CancellationError { throw CancellationError() }
                catch {
                    // A provider may report an error after creating the link.
                    // This uncommitted destination is ours; remove only that
                    // path before an ordinary copy. Once valid bytes are found,
                    // more aliases cannot make the fallback copy more correct.
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    try Task.checkCancellation()
                    break
                }
            }
            if !linked { try streamCopy(from: sourceURL, to: destination) }
            try Task.checkCancellation()
            let copy = try FileTransferArtifact.digestFile(destination)
            guard original == copy else { throw FileTransferError.invalid("导入中内容变化；没有复用不一致原件") }
            return .init(artifact: artifact, created: true)
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    private nonisolated static func streamCopy(from source: URL, to destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw FileTransferError.unavailable }
        let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation(); try output.write(contentsOf: chunk)
        }
        try output.synchronize(); try Task.checkCancellation()
    }

    func isArchived(id: UUID) -> Bool { archives.contains { $0.artifactID == id } }
    func archive(id: UUID, now: Date = Date()) throws {
        _ = try artifact(id: id)
        guard now.timeIntervalSince1970.isFinite else { throw FileTransferError.invalid("归档时间") }
        guard !isArchived(id: id) else { return }
        try save(artifacts: artifacts, operations: operations, archives: archives + [.init(artifactID: id, archivedAt: now)])
    }
    func restore(id: UUID) throws {
        _ = try artifact(id: id)
        guard isArchived(id: id) else { return }
        try save(artifacts: artifacts, operations: operations, archives: archives.filter { $0.artifactID != id })
    }
    func managementItems(referencedBySavedPlans planIDs: [UUID]) -> [FileTransferLibraryItem] {
        let plans = Set(planIDs), grouped = Dictionary(grouping: artifacts, by: { $0.sha256 + ":" + String($0.byteCount) })
        var references: [UUID: [String]] = [:]
        for operation in operations { for item in operation.manifest { references[item.id, default: []].append(operation.operationID) } }
        return artifacts.map { artifact in
            let receiptIDs = references[artifact.id] ?? []
            return .init(artifact: artifact, archivedAt: archives.first { $0.artifactID == artifact.id }?.archivedAt,
                sameContentSourceCount: grouped[artifact.sha256 + ":" + String(artifact.byteCount)]?.count ?? 1,
                receiptOperationIDs: receiptIDs, referencedBySavedPlan: plans.contains(artifact.id),
                deletionBlockReason: deletionReason(receiptIDs: receiptIDs, planReferenced: plans.contains(artifact.id)))
        }
    }
    private func deletionReason(receiptIDs: [String], planReferenced: Bool) -> String? {
        if !readable { return "资料库存储不可用，先恢复原记录" }
        if hasActiveOperation { return "有文件业务操作正在进行" }
        if hasPendingReview { return "有提交结果待核验，不能删除原件" }
        if importing || statisticsReaders > 0 { return "正在导入或核算原件，请稍后再试" }
        if !receiptIDs.isEmpty { return "已有回执 manifest 引用，原件需保留作证据" }
        if planReferenced { return "已保存自动发送范围引用，原件需保留" }
        return nil
    }
    /// Only app-managed copies are eligible. The caller MUST supply references
    /// from every saved automatic plan; no unsafe no-argument variant exists.
    func deleteUnreferenced(id: UUID, referencedBySavedPlans planIDs: [UUID]) throws {
        let artifact = try artifact(id: id)
        let receiptIDs = operations.filter { $0.manifest.contains { $0.id == id } }.map(\.operationID)
        if let reason = deletionReason(receiptIDs: receiptIDs, planReferenced: planIDs.contains(id)) { throw FileTransferError.invalid(reason) }
        guard !FileManager.default.fileExists(atPath: deletionURL.path) else { throw FileTransferError.unavailable }
        let intent = DeletionIntent(id: UUID(), artifact: artifact)
        let original = filesRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        let trash = trashRoot.appendingPathComponent(intent.id.uuidString, isDirectory: true)
        try validateManagedDirectory(filesRoot); try validateManagedDirectory(original)
        try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
        try validateManagedDirectory(trashRoot)
        do {
            try libraryIO.write(try JSONEncoder().encode(intent), deletionURL)
            try libraryIO.move(original, trash) // reversible, same app directory/volume
            try save(artifacts: artifacts.filter { $0.id != id }, operations: operations,
                     archives: archives.filter { $0.artifactID != id })
            try libraryIO.remove(trash)
            try libraryIO.remove(deletionURL)
        } catch {
            let originalError = error
            do {
                if FileManager.default.fileExists(atPath: deletionURL.path) {
                    let outcome = try recoverDeletion()
                    readable = true; self.error = ""
                    if outcome == .committed { return } // independently verified full commit+cleanup
                } else { adopt(try readDocument()) }
            } catch { readable = false; self.error = FileTransferError.unavailable.localizedDescription; throw FileTransferError.unavailable }
            throw originalError
        }
    }
    private func validateManagedDirectory(_ directory: URL) throws { try Self.validateDirectory(directory) }
    private nonisolated static func validateDirectory(_ directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw FileTransferError.unavailable }
    }
    /// Restart recovery decides from the atomically saved metadata, never from
    /// an in-memory assumption about whether a write threw before/after commit.
    private func recoverDeletion() throws -> Recovery {
        guard (try deletionURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 10000 else { throw FileTransferError.unavailable }
        let intent = try JSONDecoder().decode(DeletionIntent.self, from: Data(contentsOf: deletionURL))
        try intent.artifact.validate(); guard intent.version == 1 else { throw FileTransferError.unavailable }
        let document = try readDocument()
        try validateManagedDirectory(filesRoot)
        if FileManager.default.fileExists(atPath: trashRoot.path) { try validateManagedDirectory(trashRoot) }
        let original = filesRoot.appendingPathComponent(intent.artifact.id.uuidString, isDirectory: true)
        let trash = trashRoot.appendingPathComponent(intent.id.uuidString, isDirectory: true)
        let originalExists = FileManager.default.fileExists(atPath: original.path), trashExists = FileManager.default.fileExists(atPath: trash.path)
        if let retained = document.artifacts.first(where: { $0.id == intent.artifact.id }) {
            guard retained == intent.artifact, originalExists != trashExists else { throw FileTransferError.unavailable }
            if trashExists { try validateManagedDirectory(trash); try libraryIO.move(trash, original) }
            try validateManagedDirectory(original)
            try libraryIO.remove(deletionURL); adopt(document); return .rolledBack
        }
        guard !originalExists else { throw FileTransferError.unavailable }
        if trashExists { try validateManagedDirectory(trash); try libraryIO.remove(trash) }
        try libraryIO.remove(deletionURL); adopt(document); return .committed
    }

    func storageStatistics() throws -> FileTransferStorageStatistics {
        guard readable else { throw FileTransferError.unavailable }
        return try Self.calculateStatistics(artifacts: artifacts, archivedIDs: Set(archives.map(\.artifactID)), root: filesRoot)
    }
    func storageStatisticsAsync() async throws -> FileTransferStorageStatistics {
        guard readable else { throw FileTransferError.unavailable }
        statisticsReaders += 1; defer { statisticsReaders -= 1 }
        let values = artifacts, archived = Set(archives.map(\.artifactID)), root = filesRoot
        let worker = Task.detached { try Self.calculateStatistics(artifacts: values, archivedIDs: archived, root: root) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    private nonisolated static func calculateStatistics(artifacts: [FileTransferArtifact], archivedIDs: Set<UUID>, root: URL) throws -> FileTransferStorageStatistics {
        var actualBytes: Int64 = 0, uniqueBytes: Int64 = 0, allocated: Int64 = 0
        var seen = Set<String>(), unavailable: [UUID] = [], corrupt: [UUID] = []
        var inodeComplete = true, allocationComplete = true
        for artifact in artifacts {
            try Task.checkCancellation()
            let file = root.appendingPathComponent(artifact.relativePath)
            do {
                try validateDirectory(root); try validateDirectory(file.deletingLastPathComponent())
                let actual = try FileTransferArtifact.digestFile(file)
                actualBytes += actual.1
                guard actual.0 == artifact.sha256, actual.1 == artifact.byteCount else { corrupt.append(artifact.id); continue }
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard let device = attributes[.systemNumber] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber, inode.uint64Value > 0 else { inodeComplete = false; continue }
                let key = device.stringValue + ":" + inode.stringValue
                if seen.insert(key).inserted {
                    uniqueBytes += actual.1
                    let values = try? file.resourceValues(forKeys: [.fileAllocatedSizeKey])
                    if let amount = values?.fileAllocatedSize { allocated += Int64(amount) } else { allocationComplete = false }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { unavailable.append(artifact.id) }
        }
        let complete = inodeComplete && unavailable.isEmpty && corrupt.isEmpty
        return .init(artifactCount: artifacts.count, activeArtifactCount: artifacts.filter { !archivedIDs.contains($0.id) }.count,
            archivedArtifactCount: artifacts.filter { archivedIDs.contains($0.id) }.count,
            manifestBytes: artifacts.reduce(0) { $0 + $1.byteCount }, actualPathBytes: actualBytes,
            uniqueStoredFileBytes: complete ? uniqueBytes : nil, allocatedStoredBytes: complete && allocationComplete ? allocated : nil,
            hardLinkSavingsBytes: complete ? actualBytes - uniqueBytes : nil,
            unavailableArtifactIDs: unavailable, corruptArtifactIDs: corrupt, verifiedAt: Date())
    }

    func payloadAsync(manifest: [FileTransferManifestItem], bindingID: UUID) async throws -> FileTransferPayload {
        guard readable else { throw FileTransferError.unavailable }
        for item in manifest { guard try artifact(id: item.id) == item.artifact else { throw FileTransferError.invalid("manifest 已改变") } }
        let root = filesRoot
        let worker = Task.detached {
            let urls = try manifest.map { item -> URL in
                let url = root.appendingPathComponent(item.artifact.relativePath)
                let actual = try FileTransferArtifact.digestFile(url)
                guard actual.0 == item.artifact.sha256, actual.1 == item.artifact.byteCount else { throw FileTransferError.invalid("原件副本内容已变化") }
                return url
            }
            return FileTransferPayload(bindingID: bindingID, manifest: manifest, fileURLs: urls)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    func artifact(id: UUID) throws -> FileTransferArtifact {
        guard readable, let value = artifacts.first(where: { $0.id == id }) else { throw FileTransferError.unavailable }
        try value.validate(); return value
    }
    func operation(id: String) throws -> FileTransferOperation? {
        guard readable else { throw FileTransferError.unavailable }; return operations.first { $0.operationID == id }
    }
    func manifest(artifactIDs: [UUID]) throws -> [FileTransferManifestItem] {
        guard !artifactIDs.isEmpty, artifactIDs.count <= 50, Set(artifactIDs).count == artifactIDs.count else { throw FileTransferError.invalid("每批 1–50 个不同文件") }
        guard !artifactIDs.contains(where: { isArchived(id: $0) }) else { throw FileTransferError.invalid("已归档原件不能用于新的发送清单；请先明确恢复") }
        return try artifactIDs.enumerated().map { FileTransferManifestItem(artifact: try artifact(id: $0.element), ordinal: $0.offset) }
    }
    func payload(manifest: [FileTransferManifestItem], bindingID: UUID) throws -> FileTransferPayload {
        guard readable else { throw FileTransferError.unavailable }
        let urls = try manifest.map { item -> URL in
            guard try artifact(id: item.id) == item.artifact else { throw FileTransferError.invalid("manifest 已改变") }
            let file = filesRoot.appendingPathComponent(item.artifact.relativePath)
            let actual = try FileTransferArtifact.digestFile(file)
            guard actual.0 == item.artifact.sha256, actual.1 == item.artifact.byteCount else { throw FileTransferError.invalid("原件副本内容已变化，停止发送") }
            return file
        }
        return FileTransferPayload(bindingID: bindingID, manifest: manifest, fileURLs: urls)
    }
    func put(_ operation: FileTransferOperation) throws {
        var records = operations
        if let index = records.firstIndex(where: { $0.operationID == operation.operationID }) { records[index] = operation }
        else { records.append(operation) }
        try save(artifacts: artifacts, operations: records)
    }
    func exportData() throws -> Data {
        guard readable else { throw FileTransferError.unavailable }
        return try JSONEncoder().encode(Document(artifacts: artifacts, operations: operations, library: .init(archives: archives)))
    }
    private func readDocument() throws -> Document {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 24_000_000 else { throw FileTransferError.unavailable }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url)); try Self.validate(document); return document
    }
    private func adopt(_ document: Document) { artifacts = document.artifacts; operations = document.operations; archives = document.library?.archives ?? [] }
    private static func validate(_ document: Document) throws {
        guard document.version == 1, document.artifacts.count <= 2000, document.operations.count <= 1000,
              Set(document.artifacts.map(\.id)).count == document.artifacts.count,
              Set(document.artifacts.map(\.sourceID)).count == document.artifacts.count,
              Set(document.operations.map(\.operationID)).count == document.operations.count else { throw FileTransferError.unavailable }
        // UUID uniqueness is established above. This index exists only for this
        // validation transaction; immutable manifests still require full equality.
        let artifactsByID = Dictionary(uniqueKeysWithValues: document.artifacts.map { ($0.id, $0) })
        for value in document.artifacts { try value.validate() }
        for value in document.operations {
            try value.validate()
            for item in value.manifest { guard artifactsByID[item.id] == item.artifact else { throw FileTransferError.unavailable } }
        }
        if let library = document.library {
            guard library.version == 1, library.archives.count <= document.artifacts.count,
                  Set(library.archives.map(\.artifactID)).count == library.archives.count,
                  Set(library.archives.map(\.artifactID)).isSubset(of: Set(document.artifacts.map(\.id))),
                  library.archives.allSatisfy({ $0.archivedAt.timeIntervalSince1970.isFinite }) else { throw FileTransferError.unavailable }
        }
    }
    private func save(artifacts values: [FileTransferArtifact], operations records: [FileTransferOperation], archives archived: [FileTransferLibraryArchive]? = nil) throws {
        guard readable else { throw FileTransferError.unavailable }
        let document = Document(artifacts: values, operations: records, library: .init(archives: archived ?? archives))
        try Self.validate(document)
        let bytes = try JSONEncoder().encode(document)
        guard bytes.count <= 24_000_000 else { throw FileTransferError.unavailable }
        do {
            let folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var exclusion = URLResourceValues(); exclusion.isExcludedFromBackup = true; var directory = folder; try directory.setResourceValues(exclusion)
            try libraryIO.write(bytes, url)
            #if os(iOS)
            if FileManager.default.fileExists(atPath: filesRoot.path) { try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: filesRoot.path) }
            #endif
        } catch { readable = false; self.error = FileTransferError.unavailable.localizedDescription; throw FileTransferError.unavailable }
        adopt(document); error = ""
    }
}
