import Foundation
import CoreGraphics
import ImageIO
import Combine
import Darwin

enum AgentError: Error { case message(String) }

@main struct WorkflowDiagnosticsChecks {
    @MainActor static func main() throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func rejects(_ message: String, _ action: () throws -> Void) {
            var rejected = false; do { try action() } catch { rejected = true }; expect(rejected, message)
        }
        func image(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, type: CFString = "public.jpeg" as CFString) -> Data {
            let context = CGContext(data: nil, width: 16, height: 12, bitsPerComponent: 8, bytesPerRow: 64,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
            let result = NSMutableData()
            let destination = CGImageDestinationCreateWithData(result, type, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            precondition(CGImageDestinationFinalize(destination))
            return result as Data
        }
        let jpeg = image(0.8, 0.15, 0.25), secondJPEG = image(0.1, 0.25, 0.9)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-fixtures-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func directory(_ suffix: String) -> URL { folder.appendingPathComponent(suffix, isDirectory: true) }
        func context(_ boundary: WorkflowDiagnosticBoundary = .observed, operation: String? = nil, protected: Bool = false,
                     label: String = "临时合成原屏文字🙂", blocked: Bool = false) -> WorkflowDiagnosticContext {
            let pixelDate = Date().addingTimeInterval(-100), confirmed = Date()
            let element = PhoneUIElement(id: "ocr.fixture", label: label,
                rect: .init(x: 0.1, y: 0.2, width: 0.7, height: 0.05), source: "ocr")
            let snapshot = PhoneUISnapshot(deviceKey: "temp-diagnostic-device", scene: "xiaohongshu.note",
                elements: [element], capturedAt: pixelDate, blockingOverlay: blocked)
            return .init(workflowID: "fixture-workflow", operationID: operation, boundary: boundary, captureID: UUID(),
                capturedAt: pixelDate, confirmedAt: confirmed, snapshot: snapshot, action: "合成动作",
                reason: "离线诊断边界", result: "仅模拟回执", protectPendingSubmission: protected)
        }
        let root = directory("normal"), store = WorkflowDiagnosticsStore(directory: root)
        expect(store.error == nil, "A new temp diagnostics store initializes without reading user files")
        let observedContext = context(.beforeInput)
        let observed = try store.record(jpeg: jpeg, context: observedContext)
        expect(observed.imageStored && observed.imageStatus == .stored && observed.jpegWidth == 16 && observed.jpegHeight == 12,
            "A fully decoded real JPEG is stored with its actual dimensions")
        expect(observed.originalSHA256 == WorkflowDiagnosticRecord.sha256(jpeg) && observed.originalByteCount == jpeg.count,
            "The original JPEG digest and byte count come from unmodified supplied bytes")
        let preview = try store.preview(id: observed.id)
        expect(preview == jpeg, "Preview returns the original bytes rather than a resized or substituted image")
        expect(observed.context == observedContext && observed.context.capturedAt < observed.context.confirmedAt,
            "Pixel time, idle confirmation, capture ID, OCR, scene, action and outcome remain exact")
        let loaded = WorkflowDiagnosticsStore(directory: root)
        expect(loaded.error == nil && loaded.records == store.records, "The atomic checksum-bound index reloads exact records")
        expect(try loaded.preview(id: observed.id) == jpeg, "Reopened storage still verifies and returns the original picture")

        let invalid = try store.record(jpeg: Data("not a JPEG".utf8), context: context(.failed, blocked: true))
        expect(!invalid.imageStored && invalid.imageStatus == .notStoredInvalidJPEG && invalid.imageFilename == nil,
            "Arbitrary bytes become explicit metadata-only evidence, never a saved-picture claim")
        expect(store.error?.contains("原图未保存") == true && invalid.context.snapshot.blockingOverlay,
            "The UI can observe image failure and the original blocking-overlay evidence")
        let empty = try store.record(jpeg: Data(), context: context(.paused))
        expect(empty.imageStatus == .noImageSupplied && empty.originalByteCount == 0, "A missing picture is represented explicitly")
        let png = try store.record(jpeg: image(0.2, 0.2, 0.2, type: "public.png" as CFString), context: context(.failed))
        expect(png.imageStatus == .notStoredInvalidJPEG, "A valid PNG cannot masquerade as a JPEG diagnostic")
        let truncated = try store.record(jpeg: Data(jpeg.dropLast(8)), context: context(.failed))
        expect(truncated.imageStatus == .notStoredInvalidJPEG, "A truncated original image is not marked stored")
        rejects("Metadata-only evidence cannot provide a fake preview") { _ = try store.preview(id: invalid.id) }
        var smallSingle = WorkflowDiagnosticsPolicy.default; smallSingle.maximumSingleImageBytes = jpeg.count - 1
        let oversized = try WorkflowDiagnosticsStore(directory: directory("oversized"), policy: smallSingle).record(jpeg: jpeg, context: context())
        expect(oversized.imageStatus == .notStoredOversize && !oversized.imageStored, "Oversize bytes are not silently truncated or re-encoded")

        let exported = try store.export(ids: [observed.id, invalid.id])
        let exportedData = try Data(contentsOf: exported.url)
        let bundle = try JSONDecoder().decode(WorkflowDiagnosticsBundle.self, from: exportedData)
        expect(exportedData.count == exported.byteCount && exported.recordCount == 2 && exported.imageCount == 1,
            "One concrete shareable file contains the selected complete diagnostic entries")
        expect(bundle.entries.first?.jpeg == jpeg && bundle.entries.last?.jpeg == nil && bundle.entries.first?.record == observed,
            "The package embeds original image bytes and preserves explicit missing-picture metadata")
        expect(exported.url.isFileURL && FileManager.default.fileExists(atPath: exported.url.path), "Export is a real local file usable by ShareLink")
        if let path = ProcessInfo.processInfo.environment["DIAGNOSTIC_REPLAY_OUTPUT_DIR"] {
            let output = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try exportedData.write(to: output.appendingPathComponent("workflow-diagnostics-synthetic.json"))
            try jpeg.write(to: output.appendingPathComponent("synthetic-original-frame.jpg"))
            try Data("Synthetic offline diagnostic evidence only. The JPEG is a generated 16×12 solid-color fixture, not a user screenshot. The package was produced by the actual WorkflowDiagnosticsStore.export path and embeds these exact JPEG bytes plus synthetic OCR, capture timestamps, action and failure metadata. No device, real screen, model, metrics or network was read.\n".utf8)
                .write(to: output.appendingPathComponent("README.txt"))
        }
        rejects("Unknown selected record IDs are rejected") { _ = try store.export(ids: [UUID()]) }
        rejects("Duplicate selected records cannot inflate the diagnostic package") { _ = try store.export(ids: [observed.id, observed.id]) }
        rejects("An empty selection is not an apparently successful empty diagnostic package") { _ = try store.export(ids: []) }

        var oneImage = WorkflowDiagnosticsPolicy.default
        oneImage.maximumImages = 1; oneImage.maximumImageBytes = max(jpeg.count, secondJPEG.count)
        let retention = WorkflowDiagnosticsStore(directory: directory("images-retention"), policy: oneImage)
        let old = try retention.record(jpeg: jpeg, context: context(.observed))
        let boundary = try retention.record(jpeg: secondJPEG, context: context(.beforeInput))
        expect(boundary.imageStored && retention.records.first { $0.id == old.id }?.imageStatus == .removedByRetention,
            "A recent action boundary retains its picture ahead of an older routine observation")
        expect(retention.records.first { $0.id == old.id }?.originalSHA256 == old.originalSHA256,
            "Image eviction preserves original metadata and marks the absence truthfully")
        expect(try retention.preview(id: boundary.id) == secondJPEG, "Retention keeps exact current-boundary bytes")
        expect(WorkflowDiagnosticsStore(directory: directory("images-retention"), policy: oneImage).records == retention.records,
            "Committed metadata reflects image eviction rather than the pre-eviction encoding")
        expect(!FileManager.default.fileExists(atPath: directory("images-retention").appendingPathComponent("images/" + old.imageFilename!).path),
            "Committed image retention actually removes the evicted unprotected image")
        let protectedStore = WorkflowDiagnosticsStore(directory: directory("protected-space"), policy: oneImage)
        let pending = try protectedStore.record(jpeg: jpeg, context: context(.pendingSubmission, operation: "send-A"))
        let failure = try protectedStore.record(jpeg: secondJPEG, context: context(.failed))
        expect(pending.isProtectedPendingSubmission && !failure.imageStored && failure.imageStatus == .notStoredNoSpace,
            "Pending-send evidence is not evicted to make room, and the new picture is explicitly not stored")
        expect(try protectedStore.preview(id: pending.id) == jpeg, "The protected original remains available after image exhaustion")
        expect(WorkflowDiagnosticsStore(directory: directory("protected-space"), policy: oneImage).records == protectedStore.records,
            "No-space fallback commits metadata-only status without reusing a stored-image encoding")
        let protectedExport = try protectedStore.export()
        let cleanup = try protectedStore.clearResolved()
        expect(cleanup.removedRecords == 1 && cleanup.retainedProtectedRecords == 1 && protectedStore.records.map(\.id) == [pending.id],
            "Cleaning resolved diagnostics preserves pending-send records and originals")
        expect(cleanup.removedExports == 1 && !FileManager.default.fileExists(atPath: protectedExport.url.path),
            "Cleanup removes derived old packages while protected original evidence remains regenerable")
        expect(try WorkflowDiagnosticsStore(directory: directory("protected-space"), policy: oneImage).preview(id: pending.id) == jpeg,
            "Protection survives cleanup and process restart")

        var twoRecords = WorkflowDiagnosticsPolicy.default; twoRecords.maximumRecords = 2
        let full = WorkflowDiagnosticsStore(directory: directory("metadata-full"), policy: twoRecords)
        _ = try full.record(jpeg: jpeg, context: context(.pendingSubmission, operation: "one"))
        _ = try full.record(jpeg: jpeg, context: context(.beforeInput, operation: "two", protected: true))
        let originalIndex = try Data(contentsOf: directory("metadata-full").appendingPathComponent("index.json"))
        var errorEvents = 0
        let errorObservation = full.$error.sink { if $0 != nil { errorEvents += 1 } }
        rejects("A pending-filled metadata cap rejects another event explicitly rather than growing without bounds") {
            _ = try full.record(jpeg: jpeg, context: context(.pendingSubmission, operation: "three"))
        }
        expect(full.records.count == 2 && full.error?.contains("本次诊断未记录") == true && errorEvents > 0,
            "A not-recorded capacity outcome is published for the native UI")
        expect(try Data(contentsOf: directory("metadata-full").appendingPathComponent("index.json")) == originalIndex,
            "Capacity rejection leaves the prior atomic index byte-for-byte intact")
        _ = errorObservation
        var missingOperation = context(.pendingSubmission, operation: "required"); missingOperation.operationID = nil
        rejects("Protected-send context without a stable operation identity is rejected") { _ = try full.record(jpeg: jpeg, context: missingOperation) }
        expect(full.error?.contains("上下文") == true, "Context validation failures are also visible in published error")
        let priority = WorkflowDiagnosticsStore(directory: directory("metadata-priority"), policy: twoRecords)
        let input = try priority.record(jpeg: Data(), context: context(.beforeInput))
        let routine = try priority.record(jpeg: Data(), context: context(.observed))
        let stop = try priority.record(jpeg: Data(), context: context(.failed))
        expect(priority.records.map(\.id) == [input.id, stop.id] && !priority.records.contains { $0.id == routine.id },
            "Metadata retention preserves action boundaries and recent failures ahead of routine frames")
        rejects("A low-priority frame does not displace all the retained failure/action boundaries") { _ = try priority.record(jpeg: Data(), context: context()) }
        var repeatedPolicy = WorkflowDiagnosticsPolicy.default
        repeatedPolicy.maximumRecords = 5; repeatedPolicy.maximumImages = 2; repeatedPolicy.maximumImageBytes = jpeg.count * 2
        let repeatedRoot = directory("repeated-growth"), repeated = WorkflowDiagnosticsStore(directory: repeatedRoot, policy: repeatedPolicy)
        for _ in 0..<30 { _ = try repeated.record(jpeg: jpeg, context: context()) }
        let repeatedImages = try FileManager.default.contentsOfDirectory(at: repeatedRoot.appendingPathComponent("images"), includingPropertiesForKeys: [.fileSizeKey])
        let repeatedBytes = try repeatedImages.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        expect(repeated.records.count <= 5 && repeatedImages.count <= 2 && repeatedBytes <= repeatedPolicy.maximumImageBytes,
            "Repeated observations remain bounded in actual files and bytes as well as index counts")
        expect(WorkflowDiagnosticsStore(directory: repeatedRoot, policy: repeatedPolicy).records == repeated.records,
            "Repeated count and image trimming persist the exact final transaction record set")
        if geteuid() != 0 {
            let failedImageRoot = directory("image-write-fallback")
            let failedImageStore = WorkflowDiagnosticsStore(directory: failedImageRoot, policy: oneImage)
            let keptImage = try failedImageStore.record(jpeg: jpeg, context: context(.observed))
            let imagesPath = failedImageRoot.appendingPathComponent("images").path
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: imagesPath)
            do {
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: imagesPath) }
                let failedImage = try failedImageStore.record(jpeg: secondJPEG, context: context(.failed))
                expect(failedImage.imageStatus == .notStoredWriteFailure && !failedImage.imageStored,
                    "Real image I/O failure commits explicit metadata-only status")
                expect(WorkflowDiagnosticsStore(directory: failedImageRoot, policy: oneImage).records == failedImageStore.records,
                    "Image-write rollback persists the final encoding rather than the earlier eviction plan")
                expect(try failedImageStore.preview(id: keptImage.id) == jpeg,
                    "Image-write rollback preserves the old original that would otherwise have been evicted")
            }
        } else {
            print("Image permission-failure injection skipped under root; no permission-failure claim made")
        }
        let orphanRoot = directory("orphan-budget"), orphanStore = WorkflowDiagnosticsStore(directory: orphanRoot, policy: oneImage)
        let orphanURL = orphanRoot.appendingPathComponent("images/" + UUID().uuidString.lowercased() + ".jpg")
        try jpeg.write(to: orphanURL)
        let orphanLimited = try orphanStore.record(jpeg: secondJPEG, context: context(.failed))
        expect(orphanLimited.imageStatus == .notStoredNoSpace, "Unindexed crash remnants still count against the actual image-byte budget")
        _ = try orphanStore.clearResolved()
        expect(FileManager.default.fileExists(atPath: orphanURL.path), "Unknown orphan evidence is not automatically erased as though it were resolved")

        let release = WorkflowDiagnosticsStore(directory: directory("operation-release"))
        _ = try release.record(jpeg: jpeg, context: context(.pendingSubmission, operation: "op-A"))
        _ = try release.record(jpeg: secondJPEG, context: context(.beforeInput, operation: "op-A", protected: true))
        let other = try release.record(jpeg: jpeg, context: context(.pendingSubmission, operation: "op-B"))
        expect(try release.releaseProtection(operationID: "missing", reviewNote: "已核验") == 0, "Another operation is never unlocked by a nonmatching resolution")
        expect(try release.releaseProtection(operationID: "op-A", reviewNote: "拥有提交回执的流程已由用户逐项核验") == 2,
            "The owning send journal can release only its own resolved operation's diagnostics")
        expect(release.records.filter { $0.context.operationID == "op-A" }.allSatisfy { !$0.isProtectedPendingSubmission && $0.protectionReleasedAt != nil },
            "A release preserves an explicit review audit instead of deleting original send intent")
        _ = try release.clearResolved()
        expect(release.records.count == 1 && release.records[0].id == other.id && release.records[0].isProtectedPendingSubmission,
            "Resolving one operation never makes another operation's pending picture eligible for cleanup")

        var tinyIndex = WorkflowDiagnosticsPolicy.default; tinyIndex.maximumIndexBytes = 2048
        let indexCap = WorkflowDiagnosticsStore(directory: directory("index-cap"), policy: tinyIndex)
        rejects("A single oversized metadata record is explicitly not recorded even below the count cap") {
            _ = try indexCap.record(jpeg: jpeg, context: context(.pendingSubmission, operation: "large", label: String(repeating: "诊断", count: 2000)))
        }
        expect(indexCap.records.isEmpty && indexCap.error != nil, "Metadata byte limits prevent unbounded growth from protected OCR")
        expect(try FileManager.default.contentsOfDirectory(atPath: directory("index-cap").appendingPathComponent("images").path).isEmpty,
            "Metadata capacity is checked before writing another protected image")

        var tinyExport = WorkflowDiagnosticsPolicy.default; tinyExport.maximumExportBytes = 1024
        let exportCap = WorkflowDiagnosticsStore(directory: directory("export-cap"), policy: tinyExport)
        _ = try exportCap.record(jpeg: jpeg, context: context())
        rejects("An oversized package fails instead of emitting an incomplete share file") { _ = try exportCap.export() }
        expect(try FileManager.default.contentsOfDirectory(atPath: directory("export-cap").appendingPathComponent("exports").path).isEmpty,
            "Failed streaming export cleans up its incomplete temporary file")
        var exportPolicy = WorkflowDiagnosticsPolicy.default; exportPolicy.maximumExports = 2
        let exportRetention = WorkflowDiagnosticsStore(directory: directory("export-retention"), policy: exportPolicy)
        _ = try exportRetention.record(jpeg: jpeg, context: context(.pendingSubmission, operation: "retained"))
        let export1 = try exportRetention.export(), export2 = try exportRetention.export(), export3 = try exportRetention.export()
        expect(!FileManager.default.fileExists(atPath: export1.url.path) && FileManager.default.fileExists(atPath: export2.url.path) && FileManager.default.fileExists(atPath: export3.url.path),
            "Export copies also obey a finite recent-file retention policy")
        let exportProtectedPreview = try exportRetention.preview(id: exportRetention.records[0].id)
        expect(exportRetention.records[0].isProtectedPendingSubmission && exportProtectedPreview == jpeg,
            "Export-copy pruning does not remove the protected source picture")
        var exportBytePolicy = WorkflowDiagnosticsPolicy.default
        exportBytePolicy.maximumExports = 5; exportBytePolicy.maximumExportBytes = exported.byteCount + 2048
        exportBytePolicy.maximumStoredExportBytes = exportBytePolicy.maximumExportBytes
        let byteExportsRoot = directory("export-byte-budget")
        let byteExports = WorkflowDiagnosticsStore(directory: byteExportsRoot, policy: exportBytePolicy)
        _ = try byteExports.record(jpeg: jpeg, context: context(.beforeInput))
        _ = try byteExports.export(); _ = try byteExports.export(); _ = try byteExports.export()
        let exportFiles = try FileManager.default.contentsOfDirectory(at: byteExportsRoot.appendingPathComponent("exports"), includingPropertiesForKeys: [.fileSizeKey])
        let allExportBytes = try exportFiles.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        expect(allExportBytes <= exportBytePolicy.maximumStoredExportBytes && exportFiles.count <= exportBytePolicy.maximumExports,
            "Aggregate export bytes obey their own bound even when the file-count cap would allow more copies")

        func corruptArchive(_ name: String, mutation: (inout [String: Any]) -> Void) throws -> (URL, Data) {
            let root = directory(name), source = WorkflowDiagnosticsStore(directory: root)
            _ = try source.record(jpeg: jpeg, context: context(.pendingSubmission, operation: "protected"))
            let index = root.appendingPathComponent("index.json")
            var envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as! [String: Any]
            let payload = Data(base64Encoded: envelope["payload"] as! String)!
            var document = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
            mutation(&document)
            let changed = try JSONSerialization.data(withJSONObject: document)
            envelope["payload"] = changed.base64EncodedString(); envelope["sha256"] = WorkflowDiagnosticRecord.sha256(changed)
            let bad = try JSONSerialization.data(withJSONObject: envelope); try bad.write(to: index)
            return (root, bad)
        }
        for mutation in ["traversal", "duplicate", "overflow-size", "missing-protection", "wrong-dimensions"] {
            let (root, bytes) = try corruptArchive("invalid-" + mutation) { object in
                var values = object["records"] as! [[String: Any]]
                switch mutation {
                case "traversal": values[0]["imageFilename"] = "../../outside.jpg"
                case "duplicate": values.append(values[0])
                case "overflow-size": values[0]["originalByteCount"] = Int.max
                case "missing-protection": values[0]["isProtectedPendingSubmission"] = false
                default: values[0]["jpegWidth"] = 999
                }
                object["records"] = values
            }
            let broken = WorkflowDiagnosticsStore(directory: root)
            expect(broken.error != nil, "Strict load rejects checksum-valid invalid archive: " + mutation)
            rejects("Invalid archive is never overwritten: " + mutation) { _ = try broken.record(jpeg: jpeg, context: context()) }
            expect(try Data(contentsOf: root.appendingPathComponent("index.json")) == bytes, "Rejected index is preserved for recovery: " + mutation)
        }
        let malformedRoot = directory("malformed")
        try FileManager.default.createDirectory(at: malformedRoot, withIntermediateDirectories: true)
        let malformedBytes = Data("{interrupted-json".utf8)
        try malformedBytes.write(to: malformedRoot.appendingPathComponent("index.json"))
        let malformed = WorkflowDiagnosticsStore(directory: malformedRoot)
        rejects("A truncated index cannot be silently replaced with an empty journal") { _ = try malformed.record(jpeg: jpeg, context: context()) }
        expect(try Data(contentsOf: malformedRoot.appendingPathComponent("index.json")) == malformedBytes, "Malformed original bytes remain intact")
        let checksumRoot = directory("checksum"), checksumStore = WorkflowDiagnosticsStore(directory: checksumRoot)
        _ = try checksumStore.record(jpeg: jpeg, context: context())
        let checksumURL = checksumRoot.appendingPathComponent("index.json")
        var changedEnvelope = try JSONSerialization.jsonObject(with: Data(contentsOf: checksumURL)) as! [String: Any]
        changedEnvelope["sha256"] = String(repeating: "0", count: 64)
        let changedEnvelopeBytes = try JSONSerialization.data(withJSONObject: changedEnvelope); try changedEnvelopeBytes.write(to: checksumURL)
        let wrongChecksum = WorkflowDiagnosticsStore(directory: checksumRoot)
        expect(wrongChecksum.error != nil, "A mismatched index checksum cannot be trusted even when its JSON decodes")
        rejects("Checksum failure prevents overwriting the original evidence") { _ = try wrongChecksum.clearResolved() }
        expect(try Data(contentsOf: checksumURL) == changedEnvelopeBytes, "Checksum-invalid index bytes remain available for recovery")
        let missingRoot = directory("missing-image"), missingStore = WorkflowDiagnosticsStore(directory: missingRoot)
        let missingRecord = try missingStore.record(jpeg: jpeg, context: context(.pendingSubmission, operation: "missing-image"))
        let missingIndex = try Data(contentsOf: missingRoot.appendingPathComponent("index.json"))
        try FileManager.default.removeItem(at: missingRoot.appendingPathComponent("images/" + missingRecord.imageFilename!))
        expect(WorkflowDiagnosticsStore(directory: missingRoot).error != nil, "A missing protected original is a load failure, not a silent empty screenshot")
        expect(try Data(contentsOf: missingRoot.appendingPathComponent("index.json")) == missingIndex,
            "A missing picture does not trigger an index rewrite that would erase its original receipt")

        let outside = directory("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = outside.appendingPathComponent("private-fixture.jpg"); try secondJPEG.write(to: outsideFile)
        let rootLink = directory("root-link"); try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: outside)
        let rootSymlinkStore = WorkflowDiagnosticsStore(directory: rootLink)
        expect(rootSymlinkStore.error != nil && !FileManager.default.fileExists(atPath: outside.appendingPathComponent("index.json").path),
            "A symlink diagnostic root never writes through to its destination")
        let childRoot = directory("child-link"); try FileManager.default.createDirectory(at: childRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: childRoot.appendingPathComponent("images"), withDestinationURL: outside)
        let childLinkStore = WorkflowDiagnosticsStore(directory: childRoot)
        expect(childLinkStore.error != nil, "A symlink images directory is rejected before storing any frame")
        let indexRoot = directory("index-link"); try FileManager.default.createDirectory(at: indexRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: indexRoot.appendingPathComponent("index.json"), withDestinationURL: outsideFile)
        expect(WorkflowDiagnosticsStore(directory: indexRoot).error != nil, "A symlink index is not loaded as a diagnostic document")
        let imageRoot = directory("image-link"), imageStore = WorkflowDiagnosticsStore(directory: imageRoot)
        let imageRecord = try imageStore.record(jpeg: jpeg, context: context(.pendingSubmission, operation: "image-pending"))
        let imageURL = imageRoot.appendingPathComponent("images/" + imageRecord.imageFilename!)
        try FileManager.default.removeItem(at: imageURL)
        try FileManager.default.createSymbolicLink(at: imageURL, withDestinationURL: outsideFile)
        expect(WorkflowDiagnosticsStore(directory: imageRoot).error != nil, "A referenced image symlink cannot leak an external JPEG on load")
        rejects("Preview does not follow a replaced image symlink") { _ = try imageStore.preview(id: imageRecord.id) }
        expect(try Data(contentsOf: outsideFile) == secondJPEG, "External file bytes are neither read as a valid diagnostic nor overwritten")
        let switchedChild = directory("child-replaced"), switchedChildStore = WorkflowDiagnosticsStore(directory: switchedChild)
        _ = try switchedChildStore.record(jpeg: jpeg, context: context(.pendingSubmission, operation: "anchored"))
        try FileManager.default.moveItem(at: switchedChild.appendingPathComponent("images"), to: switchedChild.appendingPathComponent("old-images"))
        try FileManager.default.createSymbolicLink(at: switchedChild.appendingPathComponent("images"), withDestinationURL: outside)
        rejects("Replacing a managed child with a symlink after init cannot redirect a later write") {
            _ = try switchedChildStore.record(jpeg: jpeg, context: context(.failed))
        }
        expect(try Data(contentsOf: outsideFile) == secondJPEG, "Anchored file operations do not overwrite the symlink destination")
        let replacedRoot = directory("root-replaced"), replacementStore = WorkflowDiagnosticsStore(directory: replacedRoot)
        _ = try replacementStore.record(jpeg: jpeg, context: context())
        try FileManager.default.moveItem(at: replacedRoot, to: directory("root-replaced-original"))
        try FileManager.default.createDirectory(at: replacedRoot, withIntermediateDirectories: true)
        rejects("A managed directory replaced after init cannot redirect writes to another inode") { _ = try replacementStore.record(jpeg: secondJPEG, context: context()) }
        expect(!FileManager.default.fileExists(atPath: replacedRoot.appendingPathComponent("index.json").path), "Directory replacement produces no index in the replacement destination")
        print("Workflow diagnostics production checks passed: \(checks). Generated temp JPEG fixtures only; no real screenshot, clipboard, device, network, model or metrics input.")
    }
}
