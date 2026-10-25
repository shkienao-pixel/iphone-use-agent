import Foundation
import ImageIO
import Combine
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A phone-local evidence store. It has no model, metrics, network or upload
/// dependency. File operations stay anchored to opened directories, never IDs
/// or paths supplied by screen text, workflow content or a decoded filename.
@MainActor
final class WorkflowDiagnosticsStore: ObservableObject {
    static let shared = WorkflowDiagnosticsStore()
    @Published private(set) var records: [WorkflowDiagnosticRecord] = []
    @Published private(set) var error: String?
    let directory: URL
    let policy: WorkflowDiagnosticsPolicy
    private var rootFD: Int32 = -1, imagesFD: Int32 = -1, exportsFD: Int32 = -1
    private var rootIdentity: (UInt64, UInt64)?
    private var usable = true
    private struct Document: Codable { var version = 1; var records: [WorkflowDiagnosticRecord] }
    private struct Envelope: Codable { var version = 1; var payload: Data; var sha256: String }
    /// Transaction-local bytes stay paired with the exact immutable records
    /// they encode. Image writes do not require re-encoding an unchanged index.
    private struct PreparedIndex { let records: [WorkflowDiagnosticRecord]; let data: Data }

    init(directory: URL? = nil, policy: WorkflowDiagnosticsPolicy = .default) {
        let requested = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneAgent/workflow-diagnostics", isDirectory: true)
        // Resolve the trusted caller's parent once (including macOS /var). The
        // managed root itself and all managed children must never be symlinks.
        self.directory = requested.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(requested.lastPathComponent, isDirectory: true).standardizedFileURL
        self.policy = policy
        do {
            try policy.validate()
            guard requested.isFileURL, self.directory.path != "/", !requested.lastPathComponent.isEmpty,
                  requested.lastPathComponent != ".", requested.lastPathComponent != "..",
                  (try? FileManager.default.attributesOfItem(atPath: requested.path)[.type] as? FileAttributeType) != .typeSymbolicLink else {
                throw WorkflowDiagnosticsError.unsafePath
            }
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard self.directory.resolvingSymlinksInPath().path == self.directory.path else { throw WorkflowDiagnosticsError.unsafePath }
            rootFD = open(self.directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rootFD >= 0 else { throw WorkflowDiagnosticsError.unsafePath }
            var root = stat(); guard fstat(rootFD, &root) == 0 else { throw WorkflowDiagnosticsError.unavailable }
            rootIdentity = (UInt64(root.st_dev), UInt64(root.st_ino))
            imagesFD = try DiagnosticFiles.directory("images", at: rootFD)
            exportsFD = try DiagnosticFiles.directory("exports", at: rootFD)
            var excluded = self.directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? excluded.setResourceValues(values)
            if try DiagnosticFiles.info("index.json", at: rootFD) != nil {
                let data = try DiagnosticFiles.read("index.json", at: rootFD, maximum: policy.maximumIndexBytes)
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard Set(object?.keys.map { $0 } ?? []) == ["version", "payload", "sha256"] else { throw WorkflowDiagnosticsError.invalidArchive }
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                guard envelope.version == 1, envelope.sha256 == WorkflowDiagnosticRecord.sha256(envelope.payload) else {
                    throw WorkflowDiagnosticsError.invalidArchive
                }
                let document = try JSONDecoder().decode(Document.self, from: envelope.payload)
                guard document.version == 1 else { throw WorkflowDiagnosticsError.invalidArchive }
                try validate(document.records)
                for record in document.records where record.imageStored { _ = try storedImage(record) }
                records = document.records
            }
            _ = try DiagnosticFiles.files(at: imagesFD, extensions: ["jpg"])
            _ = try DiagnosticFiles.files(at: exportsFD, extensions: ["json"])
        } catch {
            usable = false
            self.error = (error as? WorkflowDiagnosticsError ?? .invalidArchive).localizedDescription
        }
    }
    deinit { if rootFD >= 0 { close(rootFD) }; if imagesFD >= 0 { close(imagesFD) }; if exportsFD >= 0 { close(exportsFD) } }

    @discardableResult
    func record(jpeg: Data, context: WorkflowDiagnosticContext) throws -> WorkflowDiagnosticRecord {
        do { return try recordImpl(jpeg: jpeg, context: context) }
        catch {
            self.error = "本次诊断未记录：" + error.localizedDescription
            throw error
        }
    }
    private func recordImpl(jpeg: Data, context: WorkflowDiagnosticContext) throws -> WorkflowDiagnosticRecord {
        try requireUsable(); try context.validate()
        let id = UUID(), geometry: (Int, Int)?
        var imageStatus: WorkflowDiagnosticImageStatus
        if jpeg.isEmpty { imageStatus = .noImageSupplied; geometry = nil }
        else if jpeg.count > policy.maximumSingleImageBytes { imageStatus = .notStoredOversize; geometry = nil }
        else if let dimensions = DiagnosticJPEG.dimensions(jpeg) { imageStatus = .stored; geometry = dimensions }
        else { imageStatus = .notStoredInvalidJPEG; geometry = nil }
        var value = WorkflowDiagnosticRecord(id: id, context: context, recordedAt: Date(), originalSHA256: .init(),
            originalByteCount: jpeg.count, imageStatus: imageStatus, imageFilename: imageStatus == .stored ? id.uuidString.lowercased() + ".jpg" : nil,
            jpegWidth: geometry?.0, jpegHeight: geometry?.1,
            isProtectedPendingSubmission: context.protectPendingSubmission || context.boundary == .pendingSubmission)
        value.originalSHA256 = WorkflowDiagnosticRecord.sha256(jpeg)
        var next = records + [value], recordDeletes = Set<String>()
        var prepared = try trimMetadata(&next, incoming: value, deletes: &recordDeletes)
        let metadataPlan = next
        var deletes = recordDeletes
        var metadataChanged = false
        if value.imageStored {
            let files = try DiagnosticFiles.files(at: imagesFD, extensions: ["jpg"])
            var bytes = files.values.reduce(0, +), images = files.count
            for name in recordDeletes { if let size = files[name] { bytes -= size; images -= 1 } }
            bytes += jpeg.count; images += 1
            while bytes > policy.maximumImageBytes || images > policy.maximumImages {
                guard let candidate = retentionCandidate(next, incoming: value, imagesOnly: true) else {
                    value.imageStatus = .notStoredNoSpace; value.imageFilename = nil
                    next = metadataPlan; deletes = recordDeletes
                    replace(value, in: &next); metadataChanged = true; break
                }
                if let name = next[candidate].imageFilename {
                    deletes.insert(name); bytes -= files[name] ?? next[candidate].originalByteCount; images -= 1
                }
                next[candidate].imageStatus = .removedByRetention; next[candidate].imageFilename = nil
                metadataChanged = true
            }
        }
        if metadataChanged { prepared = try trimMetadata(&next, incoming: value, deletes: &deletes) }
        if value.imageStored, let filename = value.imageFilename {
            do { try DiagnosticFiles.atomicWrite(jpeg, name: filename, at: imagesFD, replacing: false) }
            catch let failure as WorkflowDiagnosticsError where failure == .unsafePath { throw failure }
            catch {
                value.imageStatus = .notStoredWriteFailure; value.imageFilename = nil
                next = metadataPlan; deletes = recordDeletes; replace(value, in: &next)
                prepared = try trimMetadata(&next, incoming: value, deletes: &deletes)
            }
        }
        do { try commit(prepared, deleting: deletes) }
        catch {
            // A failed index transaction never replaces its old records. New
            // protected images stay as bounded orphans for recovery; no claim
            // that this diagnostic was recorded is returned to the caller.
            if !value.isProtectedPendingSubmission, let file = value.imageFilename { try? DiagnosticFiles.remove(file, at: imagesFD) }
            throw error
        }
        switch value.imageStatus {
        case .notStoredNoSpace: self.error = "诊断图片容量已满；本条仅保存元数据，原图未保存"
        case .notStoredOversize: self.error = "原始截图超过单图上限；本条仅保存元数据，原图未保存"
        case .notStoredInvalidJPEG: self.error = "原始字节未通过 JPEG 解码校验；本条仅保存元数据，原图未保存"
        case .notStoredWriteFailure: self.error = "原始截图写入失败；本条仅保存元数据，原图未保存"
        default: break
        }
        return records.first { $0.id == value.id }!
    }

    func preview(id: UUID) throws -> Data {
        try requireUsable()
        guard let value = records.first(where: { $0.id == id }) else { throw WorkflowDiagnosticsError.invalidSelection }
        guard value.imageStored else { throw WorkflowDiagnosticsError.imageUnavailable }
        do { return try storedImage(value) }
        catch { usable = false; self.error = WorkflowDiagnosticsError.invalidArchive.localizedDescription; throw error }
    }

    /// Produces ONE shareable local JSON file with original JPEGs encoded as
    /// base64. Entries stream one image at a time; no remote destination exists.
    func export(ids: [UUID]? = nil) throws -> WorkflowDiagnosticsExport {
        try requireUsable()
        let selected: [WorkflowDiagnosticRecord]
        if let ids {
            guard !ids.isEmpty, Set(ids).count == ids.count, ids.allSatisfy({ id in records.contains { $0.id == id } }) else {
                throw WorkflowDiagnosticsError.invalidSelection
            }
            let wanted = Set(ids); selected = records.filter { wanted.contains($0.id) }
        } else { selected = records }
        guard !selected.isEmpty else { throw WorkflowDiagnosticsError.invalidSelection }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let created = Date()
        let header = "{\"version\":1,\"createdAt\":\(created.timeIntervalSinceReferenceDate),\"notice\":\"Local diagnostic evidence only. This exporter does not upload images or send them to a model or metrics. Original screens may contain private content.\",\"entries\":["
        var estimatedBytes = header.utf8.count + 2 + selected.count - 1
        for record in selected {
            estimatedBytes += try encoder.encode(WorkflowDiagnosticsBundle.Entry(record: record, jpeg: nil)).count
            if record.imageStored { estimatedBytes += 10 + 4 * ((record.originalByteCount + 2) / 3) }
        }
        guard estimatedBytes <= policy.maximumExportBytes else { throw WorkflowDiagnosticsError.exportTooLarge }
        try reserveExportSpace(incomingBytes: estimatedBytes)
        let filename = UUID().uuidString.lowercased() + ".json"
        var images = 0, count = 0
        do {
            let bytes = try DiagnosticFiles.atomicStream(name: filename, at: exportsFD, maximum: policy.maximumExportBytes) { write in
                try write(Data(header.utf8))
                for record in selected {
                    let jpeg = record.imageStored ? try self.storedImage(record) : nil
                    if jpeg != nil { images += 1 }
                    if count > 0 { try write(Data(",".utf8)) }
                    try write(encoder.encode(WorkflowDiagnosticsBundle.Entry(record: record, jpeg: jpeg)))
                    count += 1
                }
                try write(Data("]}".utf8))
            }
            try retainExports(keeping: filename)
            return .init(url: directory.appendingPathComponent("exports/" + filename), recordCount: count, imageCount: images, byteCount: bytes)
        } catch {
            try? DiagnosticFiles.remove(filename, at: exportsFD)
            throw error
        }
    }

    @discardableResult
    func clearResolved() throws -> WorkflowDiagnosticsCleanup {
        try requireUsable()
        let removed = records.filter { !$0.isProtectedPendingSubmission }
        let keep = records.filter(\.isProtectedPendingSubmission)
        let files = Set(removed.compactMap(\.imageFilename))
        try commit(keep, deleting: files)
        var removedImages = 0, removedExports = 0
        for file in files { if (try DiagnosticFiles.info(file, at: imagesFD)) == nil { removedImages += 1 } }
        // Export files are reproducible copies. Clear them so resolved screen
        // content does not survive a user-requested cleanup inside an old pack;
        // all protected original records and original JPEGs remain untouched.
        for file in try DiagnosticFiles.files(at: exportsFD, extensions: ["json"]).keys {
            do { try DiagnosticFiles.remove(file, at: exportsFD); removedExports += 1 }
            catch { self.error = "未保护诊断已清理，部分历史导出副本未删除；保护原图保持不变" }
        }
        return .init(removedRecords: removed.count, removedImages: removedImages, retainedProtectedRecords: keep.count, removedExports: removedExports)
    }

    /// Root may call ONLY after its owning send journal confirms every pending
    /// receipt for this operation was explicitly reviewed. stillUnknown is not a
    /// resolution. There is deliberately no per-record/UI arbitrary unlock API.
    @discardableResult
    func releaseProtection(operationID: String, reviewNote: String) throws -> Int {
        try requireUsable()
        let note = reviewNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !operationID.isEmpty, !note.isEmpty, note.count <= 1000 else { throw WorkflowDiagnosticsError.invalidContext }
        var next = records, changed = 0
        for index in next.indices where next[index].context.operationID == operationID && next[index].isProtectedPendingSubmission {
            next[index].isProtectedPendingSubmission = false
            next[index].protectionReleasedAt = Date(); next[index].protectionReviewNote = note; changed += 1
        }
        if changed > 0 { try commit(next, deleting: []) }
        return changed
    }

    private func requireUsable() throws {
        guard usable else { throw WorkflowDiagnosticsError.unavailable }
        guard directory.resolvingSymlinksInPath().path == directory.path,
              let expected = rootIdentity else { throw WorkflowDiagnosticsError.unsafePath }
        var root = stat()
        guard lstat(directory.path, &root) == 0, (root.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              UInt64(root.st_dev) == expected.0, UInt64(root.st_ino) == expected.1 else { throw WorkflowDiagnosticsError.unsafePath }
        try DiagnosticFiles.verifyDirectory("images", at: rootFD, matches: imagesFD)
        try DiagnosticFiles.verifyDirectory("exports", at: rootFD, matches: exportsFD)
        if let index = try DiagnosticFiles.info("index.json", at: rootFD), !DiagnosticFiles.regular(index) { throw WorkflowDiagnosticsError.unsafePath }
    }
    private func validate(_ values: [WorkflowDiagnosticRecord]) throws {
        guard values.count <= policy.maximumRecords, Set(values.map(\.id)).count == values.count,
              values.filter(\.imageStored).count <= policy.maximumImages else {
            throw WorkflowDiagnosticsError.invalidArchive
        }
        var imageBytes = 0
        for value in values {
            try value.validate()
            if value.imageStored {
                guard value.originalByteCount <= policy.maximumSingleImageBytes,
                      value.originalByteCount <= policy.maximumImageBytes - imageBytes else { throw WorkflowDiagnosticsError.invalidArchive }
                imageBytes += value.originalByteCount
            }
        }
    }
    private func storedImage(_ value: WorkflowDiagnosticRecord) throws -> Data {
        try value.validate()
        guard value.imageStored, let file = value.imageFilename else { throw WorkflowDiagnosticsError.imageUnavailable }
        let data = try DiagnosticFiles.read(file, at: imagesFD, maximum: policy.maximumSingleImageBytes)
        guard data.count == value.originalByteCount, WorkflowDiagnosticRecord.sha256(data) == value.originalSHA256,
              let size = DiagnosticJPEG.dimensions(data), size.0 == value.jpegWidth, size.1 == value.jpegHeight else {
            throw WorkflowDiagnosticsError.invalidArchive
        }
        return data
    }
    private func replace(_ value: WorkflowDiagnosticRecord, in values: inout [WorkflowDiagnosticRecord]) {
        if let index = values.firstIndex(where: { $0.id == value.id }) { values[index] = value }
    }
    private func retentionCandidate(_ values: [WorkflowDiagnosticRecord], incoming: WorkflowDiagnosticRecord, imagesOnly: Bool = false) -> Int? {
        values.indices.filter {
            values[$0].id != incoming.id && !values[$0].isProtectedPendingSubmission &&
                values[$0].context.boundary.retentionPriority <= incoming.context.boundary.retentionPriority &&
                (!imagesOnly || values[$0].imageStored)
        }.min { lhs, rhs in
            let a = values[lhs], b = values[rhs]
            return a.context.boundary.retentionPriority == b.context.boundary.retentionPriority ? a.recordedAt < b.recordedAt :
                a.context.boundary.retentionPriority < b.context.boundary.retentionPriority
        }
    }
    private func trimMetadata(_ values: inout [WorkflowDiagnosticRecord], incoming: WorkflowDiagnosticRecord, deletes: inout Set<String>) throws -> PreparedIndex {
        while true {
            let data = try encodedUnchecked(values)
            guard values.count > policy.maximumRecords || data.count > policy.maximumIndexBytes else {
                return PreparedIndex(records: values, data: data)
            }
            guard let index = retentionCandidate(values, incoming: incoming) else { throw WorkflowDiagnosticsError.capacity }
            if let file = values[index].imageFilename { deletes.insert(file) }
            values.remove(at: index)
        }
    }
    private func encodedUnchecked(_ values: [WorkflowDiagnosticRecord]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(Document(records: values))
        return try encoder.encode(Envelope(payload: payload, sha256: WorkflowDiagnosticRecord.sha256(payload)))
    }
    private func commit(_ values: [WorkflowDiagnosticRecord], deleting: Set<String>) throws {
        try commit(PreparedIndex(records: values, data: try encodedUnchecked(values)), deleting: deleting)
    }
    private func commit(_ prepared: PreparedIndex, deleting: Set<String>) throws {
        let values = prepared.records, data = prepared.data
        try validate(values)
        guard data.count <= policy.maximumIndexBytes else { throw WorkflowDiagnosticsError.capacity }
        try requireUsable()
        try DiagnosticFiles.atomicWrite(data, name: "index.json", at: rootFD, replacing: true)
        records = values; error = nil
        for file in deleting {
            do { try DiagnosticFiles.remove(file, at: imagesFD) }
            catch { self.error = "诊断索引已保存，部分旧图片未清理；未删除保护证据" }
        }
    }
    private func retainExports(keeping: String) throws {
        var files = try DiagnosticFiles.files(at: exportsFD, extensions: ["json"])
        guard files[keeping] != nil else { throw WorkflowDiagnosticsError.unavailable }
        let others = files.keys.filter { $0 != keeping }.sorted { a, b in
            let aTime = (try? DiagnosticFiles.info(a, at: exportsFD))?.st_mtimespec
            let bTime = (try? DiagnosticFiles.info(b, at: exportsFD))?.st_mtimespec
            if aTime?.tv_sec != bTime?.tv_sec { return (aTime?.tv_sec ?? 0) < (bTime?.tv_sec ?? 0) }
            if aTime?.tv_nsec != bTime?.tv_nsec { return (aTime?.tv_nsec ?? 0) < (bTime?.tv_nsec ?? 0) }
            return a < b
        }
        for file in others where files.count > policy.maximumExports || files.values.reduce(0, +) > policy.maximumStoredExportBytes {
            try DiagnosticFiles.remove(file, at: exportsFD); files.removeValue(forKey: file)
        }
        guard files.count <= policy.maximumExports && files.values.reduce(0, +) <= policy.maximumStoredExportBytes else {
            throw WorkflowDiagnosticsError.exportTooLarge
        }
    }
    private func reserveExportSpace(incomingBytes: Int) throws {
        var files = try DiagnosticFiles.files(at: exportsFD, extensions: ["json"])
        let ordered = files.keys.sorted { a, b in
            let x = (try? DiagnosticFiles.info(a, at: exportsFD))?.st_mtimespec
            let y = (try? DiagnosticFiles.info(b, at: exportsFD))?.st_mtimespec
            if x?.tv_sec != y?.tv_sec { return (x?.tv_sec ?? 0) < (y?.tv_sec ?? 0) }
            if x?.tv_nsec != y?.tv_nsec { return (x?.tv_nsec ?? 0) < (y?.tv_nsec ?? 0) }
            return a < b
        }
        for file in ordered where files.count + 1 > policy.maximumExports || files.values.reduce(0, +) + incomingBytes > policy.maximumStoredExportBytes {
            try DiagnosticFiles.remove(file, at: exportsFD); files.removeValue(forKey: file)
        }
        guard files.count + 1 <= policy.maximumExports, files.values.reduce(0, +) + incomingBytes <= policy.maximumStoredExportBytes else {
            throw WorkflowDiagnosticsError.exportTooLarge
        }
    }
}

private enum DiagnosticJPEG {
    static func dimensions(_ data: Data) -> (Int, Int)? {
        guard data.count >= 4, data.prefix(2) == Data([0xff, 0xd8]), data.suffix(2) == Data([0xff, 0xd9]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.jpeg", CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16384, height <= 16384, Int64(width) * Int64(height) <= 50_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == width, image.height == height else { return nil }
        return (width, height)
    }
}

private enum DiagnosticFiles {
    static func regular(_ value: stat) -> Bool { (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) && value.st_nlink == 1 }
    static func safeName(_ value: String) -> Bool { !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.utf8.contains(0) }
    static func info(_ name: String, at directory: Int32) throws -> stat? {
        guard safeName(name) else { throw WorkflowDiagnosticsError.unsafePath }
        var result = stat()
        if fstatat(directory, name, &result, AT_SYMLINK_NOFOLLOW) == 0 { return result }
        if errno == ENOENT { return nil }; throw WorkflowDiagnosticsError.unavailable
    }
    static func directory(_ name: String, at parent: Int32) throws -> Int32 {
        guard safeName(name) else { throw WorkflowDiagnosticsError.unsafePath }
        if try info(name, at: parent) == nil, mkdirat(parent, name, 0o700) != 0 { throw WorkflowDiagnosticsError.unavailable }
        let handle = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard handle >= 0 else { throw WorkflowDiagnosticsError.unsafePath }; return handle
    }
    static func verifyDirectory(_ name: String, at parent: Int32, matches handle: Int32) throws {
        guard let entry = try info(name, at: parent) else { throw WorkflowDiagnosticsError.unsafePath }
        var opened = stat()
        guard (entry.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR), fstat(handle, &opened) == 0,
              entry.st_dev == opened.st_dev, entry.st_ino == opened.st_ino else { throw WorkflowDiagnosticsError.unsafePath }
    }
    static func read(_ name: String, at directory: Int32, maximum: Int) throws -> Data {
        guard let info = try info(name, at: directory), regular(info), info.st_size >= 0, info.st_size <= maximum else {
            throw WorkflowDiagnosticsError.invalidArchive
        }
        let handle = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard handle >= 0 else { throw WorkflowDiagnosticsError.unsafePath }; defer { close(handle) }
        var opened = stat()
        guard fstat(handle, &opened) == 0, regular(opened), opened.st_dev == info.st_dev, opened.st_ino == info.st_ino,
              opened.st_size == info.st_size else { throw WorkflowDiagnosticsError.unsafePath }
        var data = Data(count: Int(opened.st_size))
        try data.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.read(handle, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw WorkflowDiagnosticsError.invalidArchive }; offset += count
            }
        }
        var extra: UInt8 = 0
        guard Darwin.read(handle, &extra, 1) == 0 else { throw WorkflowDiagnosticsError.invalidArchive }
        return data
    }
    static func write(_ data: Data, handle: Int32) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(handle, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw WorkflowDiagnosticsError.unavailable }; offset += count
            }
        }
    }
    static func atomicWrite(_ data: Data, name: String, at directory: Int32, replacing: Bool) throws {
        _ = try atomicStream(name: name, at: directory, maximum: max(1, data.count), replacing: replacing) { append in try append(data) }
    }
    static func atomicStream(name: String, at directory: Int32, maximum: Int, replacing: Bool = false,
                             body: (_ append: (Data) throws -> Void) throws -> Void) throws -> Int {
        guard safeName(name) else { throw WorkflowDiagnosticsError.unsafePath }
        if let existing = try info(name, at: directory), !regular(existing) || !replacing { throw WorkflowDiagnosticsError.unsafePath }
        let temporary = ".tmp-" + UUID().uuidString.lowercased()
        let handle = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard handle >= 0 else { throw WorkflowDiagnosticsError.unavailable }
        var renamed = false; defer { close(handle); if !renamed { unlinkat(directory, temporary, 0) } }
        var written = 0
        try body { data in
            guard data.count <= maximum - written else { throw WorkflowDiagnosticsError.exportTooLarge }
            try write(data, handle: handle); written += data.count
        }
        guard fsync(handle) == 0 else { throw WorkflowDiagnosticsError.unavailable }
        if let existing = try info(name, at: directory), !regular(existing) || !replacing { throw WorkflowDiagnosticsError.unsafePath }
        guard renameat(directory, temporary, directory, name) == 0 else { throw WorkflowDiagnosticsError.unavailable }
        renamed = true; _ = fsync(directory); return written
    }
    static func remove(_ name: String, at directory: Int32) throws {
        guard let entry = try info(name, at: directory) else { return }
        guard regular(entry), unlinkat(directory, name, 0) == 0 else { throw WorkflowDiagnosticsError.unsafePath }
    }
    static func files(at handle: Int32, extensions allowed: [String]) throws -> [String: Int] {
        let duplicate = dup(handle)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else { if duplicate >= 0 { close(duplicate) }; throw WorkflowDiagnosticsError.unavailable }
        defer { closedir(directory) }
        rewinddir(directory)
        var result: [String: Int] = [:]
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            let temporaryID = name.hasPrefix(".tmp-") ? UUID(uuidString: String(name.dropFirst(5))) : nil
            let ordinary = allowed.contains { suffix in
                guard name.hasSuffix("." + suffix) else { return false }
                let stem = String(name.dropLast(suffix.count + 1))
                return UUID(uuidString: stem)?.uuidString.lowercased() == stem
            }
            guard result.count < 8192, let info = try info(name, at: handle), regular(info), info.st_size >= 0, info.st_size <= 1024 * 1024 * 1024,
                  temporaryID != nil || ordinary else {
                throw WorkflowDiagnosticsError.unsafePath
            }
            result[name] = Int(info.st_size)
        }
        return result
    }
}
