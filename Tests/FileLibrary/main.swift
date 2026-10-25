import Foundation

enum LibraryFixtureError: Error { case injected }
@MainActor final class FaultState { var failBeforeWrite = false; var failAfterWrite = false; var failAfterMove = false; var failTrashRemoval = false }
final class LibraryLinkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@main struct FileLibraryChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message); checks += 1 }
        func rejected(_ message: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure(message) } catch { checks += 1 }
        }
        func rejectedAsync(_ message: String, _ body: () async throws -> Void) async {
            do { try await body(); preconditionFailure(message) } catch { checks += 1 }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("file-library-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let aURL = root.appendingPathComponent("sources-a/original.txt"), aliasURL = root.appendingPathComponent("sources-b/renamed.txt"), otherURL = root.appendingPathComponent("sources-c/original.txt")
        for file in [aURL, aliasURL, otherURL] { try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true) }
        let originalBytes = Data("中文😀原始bytes\n".utf8), otherBytes = Data("中文😀另外bytes\n".utf8)
        try originalBytes.write(to: aURL); try originalBytes.write(to: aliasURL); try otherBytes.write(to: otherURL)
        var caseNumber = 0
        func fixture(io: FileTransferLibraryIO? = nil) -> FileTransferStore {
            caseNumber += 1
            return FileTransferStore(url: root.appendingPathComponent("case-\(caseNumber)/library.json"), libraryIO: io)
        }
        func managed(_ store: FileTransferStore, _ artifact: FileTransferArtifact) -> URL {
            store.url.deletingLastPathComponent().appendingPathComponent("original-files/" + artifact.relativePath)
        }
        func inode(_ file: URL) throws -> String {
            let values = try FileManager.default.attributesOfItem(atPath: file.path)
            return String(describing: values[.systemNumber]!) + ":" + String(describing: values[.systemFileNumber]!)
        }
        func receipt(_ artifacts: [FileTransferArtifact], pending: Bool = false) -> FileTransferOperation {
            let manifest = artifacts.enumerated().map { FileTransferManifestItem(artifact: $0.element, ordinal: $0.offset) }
            let now = Date()
            return .init(operationID: "preserved-receipt", taskID: "authorized-old-task", recipient: .selfTransfer(artifactIDs: artifacts.map(\.id)),
                manifest: manifest, environment: .init(deviceKey: "phone", accessoryKey: "accessory", captureSessionID: "capture", foreground: true),
                payloadBindingID: UUID(), stage: pending ? .pendingReview : .prepared,
                items: artifacts.map { .init(artifactID: $0.id, state: pending ? .unknown : .notSubmitted,
                    attemptCount: pending ? 1 : 0, submittedAt: pending ? now : nil) }, createdAt: now, updatedAt: now)
        }

        let store = fixture()
        let a = try store.importFile(at: aURL, sourceID: "source-A", mediaType: "public.plain-text")
        let alias = try await store.importFileAsync(at: aliasURL, sourceID: "source-B", mediaType: "public.plain-text")
        expect(a.id != alias.id && a.sourceID != alias.sourceID && a.filename == "original.txt" && alias.filename == "renamed.txt", "content reuse preserves independent IDs, sources and original filenames")
        expect(a.sha256 == alias.sha256 && a.byteCount == alias.byteCount && a.importedAt <= alias.importedAt, "content and provenance timestamps are retained")
        expect(try! inode(managed(store, a)) == inode(managed(store, alias)), "actual filesystem hard link reuses one physical inode")
        let sourceAgain = try await store.importFileAsync(at: aliasURL, sourceID: "source-B", mediaType: "public.plain-text")
        expect(sourceAgain == alias && store.artifacts.count == 2, "same source/name/type/content is idempotent without timestamp or manifest mutation")
        rejected("source ID cannot change name") { _ = try store.importFile(at: aURL, sourceID: "source-B", mediaType: "public.plain-text") }
        await rejectedAsync("source ID cannot change content") { _ = try await store.importFileAsync(at: otherURL, sourceID: "source-A", mediaType: "public.plain-text") }
        expect(store.artifacts == [a, alias], "source conflicts never overwrite prior import provenance")
        let other = try store.importFile(at: otherURL, sourceID: "source-C", mediaType: "public.plain-text")
        expect(other.filename == a.filename && other.byteCount == a.byteCount && other.sha256 != a.sha256 && (try! inode(managed(store, other))) != (try! inode(managed(store, a))), "same name/size with different bytes does not deduplicate")
        let stats = try await store.storageStatisticsAsync()
        expect(stats.complete && stats.artifactCount == 3 && stats.manifestBytes == a.byteCount + alias.byteCount + other.byteCount, "logical manifest bytes count all independent sources")
        expect(stats.actualPathBytes == stats.manifestBytes && stats.uniqueStoredFileBytes == a.byteCount + other.byteCount && stats.hardLinkSavingsBytes == alias.byteCount, "savings are measured from actual device+inode identity")
        expect(store.managementItems(referencedBySavedPlans: [a.id]).first { $0.id == a.id }?.referencedBySavedPlan == true, "management list reports protected plans")
        expect(store.managementItems(referencedBySavedPlans: []).first { $0.id == a.id }?.sameContentSourceCount == 2, "management lists independent matching-content sources")

        let oldManifest = try store.manifest(artifactIDs: [a.id])
        try store.put(receipt([a]))
        try store.archive(id: a.id)
        expect(store.isArchived(id: a.id) && (try! store.artifact(id: a.id)) == a, "archive metadata never mutates immutable artifact identity")
        rejected("archived sources excluded from new manifests") { _ = try store.manifest(artifactIDs: [a.id]) }
        expect(try! Data(contentsOf: store.payload(manifest: oldManifest, bindingID: UUID()).fileURLs[0]) == originalBytes, "existing receipt payload remains readable after archive")
        expect(store.operations[0].manifest == oldManifest, "old receipt manifest remains byte-for-byte equal")
        let archivedStats = try store.storageStatistics()
        expect(archivedStats.archivedArtifactCount == 1 && archivedStats.activeArtifactCount == 2, "archive visibility and storage counts are separate")
        let reopened = FileTransferStore(url: store.url)
        expect(reopened.isArchived(id: a.id) && reopened.operations[0].manifest == oldManifest, "archive and immutable evidence survive restart")
        try reopened.restore(id: a.id)
        expect(!reopened.isArchived(id: a.id) && (try! reopened.manifest(artifactIDs: [a.id])) == oldManifest, "explicit restore re-enables new selection")
        rejected("all receipt references protect physical original") { try reopened.deleteUnreferenced(id: a.id, referencedBySavedPlans: []) }
        rejected("saved plan references protect otherwise unreferenced alias") { try reopened.deleteUnreferenced(id: alias.id, referencedBySavedPlans: [alias.id]) }
        try reopened.claim(operationID: "active-business")
        rejected("active business blocks deletion globally") { try reopened.deleteUnreferenced(id: other.id, referencedBySavedPlans: []) }
        reopened.release(operationID: "active-business")
        var pending = receipt([a], pending: true); pending.operationID = "pending-business"
        try reopened.put(pending)
        rejected("pending review blocks unrelated deletion globally") { try reopened.deleteUnreferenced(id: other.id, referencedBySavedPlans: []) }
        pending.items[0].state = .userReportedSubmitted; pending.stage = .partial
        try reopened.put(pending)
        try reopened.archive(id: alias.id)
        try reopened.deleteUnreferenced(id: alias.id, referencedBySavedPlans: [])
        expect(!reopened.artifacts.contains { $0.id == alias.id } && !reopened.isArchived(id: alias.id) && !FileManager.default.fileExists(atPath: managed(reopened, alias).path), "unreferenced managed alias deletion commits metadata and physical path together")
        expect(try! Data(contentsOf: managed(reopened, a)) == originalBytes, "deleting one hard-link alias preserves referenced original bytes")
        expect(try! Data(contentsOf: aURL) == originalBytes && Data(contentsOf: aliasURL) == originalBytes, "external user source paths are never removed or modified")
        let afterDelete = try reopened.storageStatistics()
        expect(afterDelete.hardLinkSavingsBytes == 0 && afterDelete.uniqueStoredFileBytes == a.byteCount + other.byteCount, "post-delete space stats reflect actual remaining inodes")

        var fallbackIO = FileTransferLibraryIO.system
        fallbackIO.link = { _, _ in throw LibraryFixtureError.injected }
        let fallback = fixture(io: fallbackIO)
        let firstFallback = try fallback.importFile(at: aURL, sourceID: "fallback-A", mediaType: "public.plain-text")
        let secondFallback = try await fallback.importFileAsync(at: aliasURL, sourceID: "fallback-B", mediaType: "public.plain-text")
        let fallbackStats = try await fallback.storageStatisticsAsync()
        expect((try! inode(managed(fallback, firstFallback))) != (try! inode(managed(fallback, secondFallback))) && fallbackStats.hardLinkSavingsBytes == 0, "unsupported hard links fall back to a real copy without fake savings")
        expect(fallbackStats.uniqueStoredFileBytes == firstFallback.byteCount + secondFallback.byteCount, "fallback copies count their actual distinct inodes")

        let linkCounter = LibraryLinkCounter()
        var scalingIO = FileTransferLibraryIO.system
        scalingIO.link = { _, _ in linkCounter.increment(); throw LibraryFixtureError.injected }
        let scaling = fixture(io: scalingIO)
        for index in 0..<50 {
            if index.isMultiple(of: 2) {
                _ = try scaling.importFile(at: aURL, sourceID: "fallback-scale-\(index)", mediaType: "public.plain-text")
            } else {
                _ = try await scaling.importFileAsync(at: aURL, sourceID: "fallback-scale-\(index)", mediaType: "public.plain-text")
            }
        }
        expect(linkCounter.count == 49 && scaling.artifacts.count == 50, "50 independent imports attempt one verified candidate link each, not all earlier aliases (previously 1225)")
        expect(try! scaling.storageStatistics().uniqueStoredFileBytes == Int64(originalBytes.count * 50), "failed-link scaling case has 50 real verified copies, with no fake savings")
        expect(FileTransferStore(url: scaling.url).artifacts == scaling.artifacts, "all fallback source IDs and immutable provenance survive reopen")

        let afterLinkCount = LibraryLinkCounter()
        var afterLinkIO = FileTransferLibraryIO.system
        afterLinkIO.link = { from, to in
            afterLinkCount.increment(); try FileManager.default.linkItem(at: from, to: to)
            throw LibraryFixtureError.injected
        }
        let afterLink = fixture(io: afterLinkIO)
        let linkOriginal = try afterLink.importFile(at: aURL, sourceID: "after-link-A", mediaType: "public.plain-text")
        let linkFallback = try await afterLink.importFileAsync(at: aliasURL, sourceID: "after-link-B", mediaType: "public.plain-text")
        expect(afterLinkCount.count == 1 && (try! inode(managed(afterLink, linkOriginal))) != (try! inode(managed(afterLink, linkFallback))), "error after creating link removes only owned destination then creates an independent copy")
        expect(try! Data(contentsOf: managed(afterLink, linkOriginal)) == originalBytes && Data(contentsOf: managed(afterLink, linkFallback)) == originalBytes, "after-created-link fallback preserves every original and copied byte")

        // Changing the copy source after its initial SHA proves that ordinary
        // fallback still verifies the complete destination against that SHA.
        let mutableSource = root.appendingPathComponent("mutable-source.txt")
        try originalBytes.write(to: mutableSource)
        var mutationIO = FileTransferLibraryIO.system
        mutationIO.link = { _, _ in
            try Data(repeating: 88, count: originalBytes.count).write(to: mutableSource)
            throw LibraryFixtureError.injected
        }
        let changedFallback = fixture(io: mutationIO)
        let unchangedCandidate = try changedFallback.importFile(at: mutableSource, sourceID: "mutation-A", mediaType: "public.plain-text")
        await rejectedAsync("copied destination is checked against the initial source SHA, including same-size mutations") {
            _ = try await changedFallback.importFileAsync(at: mutableSource, sourceID: "mutation-B", mediaType: "public.plain-text")
        }
        expect(changedFallback.artifacts == [unchangedCandidate] && (try! Data(contentsOf: managed(changedFallback, unchangedCandidate))) == originalBytes, "failed destination SHA never commits a changed original or damages the candidate")
        expect((try! FileManager.default.contentsOfDirectory(at: changedFallback.url.deletingLastPathComponent().appendingPathComponent("original-files"), includingPropertiesForKeys: nil)).count == 1, "failed fallback SHA cleans only its uncommitted import directory")

        var linkedMutationIO = FileTransferLibraryIO.system
        linkedMutationIO.link = { from, to in
            try FileManager.default.linkItem(at: from, to: to)
            // Modify the linked inode in place, without atomic replacement.
            let handle = try FileHandle(forWritingTo: to); defer { try? handle.close() }
            try handle.write(contentsOf: Data(repeating: 89, count: originalBytes.count))
        }
        let changedLink = fixture(io: linkedMutationIO)
        let changedLinkOriginal = try changedLink.importFile(at: aURL, sourceID: "linked-mutation-A", mediaType: "public.plain-text")
        await rejectedAsync("successful link does not skip destination SHA") {
            _ = try await changedLink.importFileAsync(at: aliasURL, sourceID: "linked-mutation-B", mediaType: "public.plain-text")
        }
        expect(changedLink.artifacts == [changedLinkOriginal] && (try! changedLink.storageStatistics().corruptArtifactIDs) == [changedLinkOriginal.id], "a mutated linked candidate is reported corrupt, never recorded as a verified new import")

        for cancelAfterCreating in [false, true] {
            let cancelCount = LibraryLinkCounter()
            var cancelIO = FileTransferLibraryIO.system
            cancelIO.link = { from, to in
                cancelCount.increment()
                if cancelAfterCreating { try FileManager.default.linkItem(at: from, to: to) }
                throw CancellationError()
            }
            let cancelled = fixture(io: cancelIO)
            let retained = try cancelled.importFile(at: aURL, sourceID: "cancel-A", mediaType: "public.plain-text")
            do {
                _ = try await cancelled.importFileAsync(at: aliasURL, sourceID: "cancel-B", mediaType: "public.plain-text")
                preconditionFailure("CancellationError must not become a successful copy")
            } catch is CancellationError { checks += 1 }
            expect(cancelCount.count == 1 && cancelled.artifacts == [retained] && (try! Data(contentsOf: managed(cancelled, retained))) == originalBytes, "link cancellation preserves original type and prior bytes (created=\(cancelAfterCreating))")
            expect((try! FileManager.default.contentsOfDirectory(at: cancelled.url.deletingLastPathComponent().appendingPathComponent("original-files"), includingPropertiesForKeys: nil)).count == 1, "cancelled link/copy does not leave an orphan import")
        }

        var taskCancelIO = FileTransferLibraryIO.system
        taskCancelIO.link = { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            throw LibraryFixtureError.injected
        }
        let taskCancelled = fixture(io: taskCancelIO)
        let taskRetained = try taskCancelled.importFile(at: aURL, sourceID: "task-cancel-A", mediaType: "public.plain-text")
        do {
            _ = try await taskCancelled.importFileAsync(at: aliasURL, sourceID: "task-cancel-B", mediaType: "public.plain-text")
            preconditionFailure("cancelled worker must not fall back to a copy")
        } catch is CancellationError { checks += 1 }
        expect(taskCancelled.artifacts == [taskRetained], "a cancelled link worker cannot turn a generic provider error into a committed fallback")

        let corrupt = fixture()
        let oldCorrupt = try corrupt.importFile(at: aURL, sourceID: "corrupt-old", mediaType: "public.plain-text")
        try Data("tampered".utf8).write(to: managed(corrupt, oldCorrupt))
        let fresh = try await corrupt.importFileAsync(at: aliasURL, sourceID: "fresh-valid", mediaType: "public.plain-text")
        expect(try! Data(contentsOf: managed(corrupt, fresh)) == originalBytes, "matching metadata cannot reuse corrupted stored bytes")
        expect((try! inode(managed(corrupt, oldCorrupt))) != (try! inode(managed(corrupt, fresh))), "corrupt candidate is not linked into fresh source")
        let corruptStats = try await corrupt.storageStatisticsAsync()
        expect(corruptStats.corruptArtifactIDs == [oldCorrupt.id] && corruptStats.uniqueStoredFileBytes == nil && corruptStats.hardLinkSavingsBytes == nil, "corrupt bytes make complete space/savings unknown, not zero")
        rejected("source idempotency rechecks actual prior bytes") { _ = try corrupt.importFile(at: aURL, sourceID: "corrupt-old", mediaType: "public.plain-text") }
        try FileManager.default.removeItem(at: managed(corrupt, fresh))
        let missingStats = try corrupt.storageStatistics()
        expect(missingStats.unavailableArtifactIDs == [fresh.id] && !missingStats.complete, "missing originals are explicitly unavailable")

        // Both corrupt and missing candidates must still be skipped in favour
        // of a later candidate whose actual bytes pass the complete hash.
        let candidateCalls = LibraryLinkCounter()
        var candidateIO = FileTransferLibraryIO.system
        candidateIO.link = { from, to in candidateCalls.increment(); try FileManager.default.linkItem(at: from, to: to) }
        let candidates = fixture(io: candidateIO)
        let damaged = try candidates.importFile(at: aURL, sourceID: "candidate-damaged", mediaType: "public.plain-text")
        try otherBytes.write(to: managed(candidates, damaged))
        let missing = try candidates.importFile(at: aURL, sourceID: "candidate-missing", mediaType: "public.plain-text")
        try FileManager.default.removeItem(at: managed(candidates, missing))
        let valid = try candidates.importFile(at: aURL, sourceID: "candidate-valid", mediaType: "public.plain-text")
        let found = try await candidates.importFileAsync(at: aliasURL, sourceID: "candidate-found", mediaType: "public.plain-text")
        expect(candidateCalls.count == 1 && (try! inode(managed(candidates, valid))) == (try! inode(managed(candidates, found))), "corrupt/missing candidates remain skippable before the first valid candidate is linked")

        let concurrent = fixture()
        async let concurrentA = concurrent.importFileAsync(at: aURL, sourceID: "one-source", mediaType: "public.plain-text")
        async let concurrentB = concurrent.importFileAsync(at: aURL, sourceID: "one-source", mediaType: "public.plain-text")
        let results = try await (concurrentA, concurrentB)
        expect(results.0 == results.1 && concurrent.artifacts.count == 1, "concurrent async same-source imports serialize idempotently")
        async let concurrentC = concurrent.importFileAsync(at: aURL, sourceID: "other-source-A", mediaType: "public.plain-text")
        async let concurrentD = concurrent.importFileAsync(at: aliasURL, sourceID: "other-source-B", mediaType: "public.plain-text")
        _ = try await (concurrentC, concurrentD)
        expect(try! concurrent.storageStatistics().hardLinkSavingsBytes == Int64(originalBytes.count * 2), "concurrent distinct sources deduplicate against latest committed originals")

        func faultIO(_ state: FaultState) -> FileTransferLibraryIO {
            let actual = FileTransferLibraryIO.system
            return .init(write: { bytes, url in
                let metadata = url.lastPathComponent == "library.json"
                if metadata && state.failBeforeWrite { throw LibraryFixtureError.injected }
                try actual.write(bytes, url)
                if metadata && state.failAfterWrite { throw LibraryFixtureError.injected }
            }, move: { from, to in
                try actual.move(from, to)
                if state.failAfterMove { state.failAfterMove = false; throw LibraryFixtureError.injected }
            }, remove: { url in
                if state.failTrashRemoval && url.deletingLastPathComponent().lastPathComponent == "file-library-trash" { throw LibraryFixtureError.injected }
                try actual.remove(url)
            })
        }
        let beforeFault = FaultState(), beforeFailure = fixture(io: faultIO(beforeFault))
        let beforeArtifact = try beforeFailure.importFile(at: aURL, sourceID: "before-write", mediaType: "public.plain-text")
        try beforeFailure.archive(id: beforeArtifact.id)
        beforeFault.failBeforeWrite = true
        rejected("metadata write failure must roll back original move") { try beforeFailure.deleteUnreferenced(id: beforeArtifact.id, referencedBySavedPlans: []) }
        expect(beforeFailure.readable && beforeFailure.artifacts == [beforeArtifact] && beforeFailure.isArchived(id: beforeArtifact.id), "failed metadata commit restores old metadata and archive state")
        expect(try! Data(contentsOf: managed(beforeFailure, beforeArtifact)) == originalBytes, "failed delete restores actual original path bytes")
        expect(!FileManager.default.fileExists(atPath: beforeFailure.url.appendingPathExtension("deletion.json").path), "successful rollback clears only completed deletion intent")

        let moveFault = FaultState(), moveFailure = fixture(io: faultIO(moveFault))
        let movedArtifact = try moveFailure.importFile(at: aURL, sourceID: "after-move", mediaType: "public.plain-text")
        moveFault.failAfterMove = true
        rejected("move error after rename must recover from actual disk state") { try moveFailure.deleteUnreferenced(id: movedArtifact.id, referencedBySavedPlans: []) }
        expect(moveFailure.readable && moveFailure.artifacts == [movedArtifact] && (try! Data(contentsOf: managed(moveFailure, movedArtifact))) == originalBytes,
               "reported move failure restores actual original instead of assuming it stayed in place")
        let committedImportFault = FaultState(), committedImport = fixture(io: faultIO(committedImportFault))
        committedImportFault.failAfterWrite = true
        let committedImportArtifact = try await committedImport.importFileAsync(at: aURL, sourceID: "committed-import", mediaType: "public.plain-text")
        expect(committedImport.readable && (try! Data(contentsOf: managed(committedImport, committedImportArtifact))) == originalBytes,
               "import writer error after atomic commit never removes durably referenced bytes")
        let emptyImportFault = FaultState(), emptyImport = fixture(io: faultIO(emptyImportFault))
        emptyImportFault.failBeforeWrite = true
        await rejectedAsync("failed first import has no committed artifact") { _ = try await emptyImport.importFileAsync(at: aURL, sourceID: "failed-import", mediaType: "public.plain-text") }
        expect(emptyImport.readable && emptyImport.artifacts.isEmpty && !FileManager.default.fileExists(atPath: emptyImport.url.path),
               "known failed first import clears only its private staging path")

        let linkedWriteFault = FaultState(), linkedWriteFailure = fixture(io: faultIO(linkedWriteFault))
        let linkedWriteRetained = try linkedWriteFailure.importFile(at: aURL, sourceID: "linked-write-A", mediaType: "public.plain-text")
        linkedWriteFault.failBeforeWrite = true
        await rejectedAsync("failed metadata write after successful verified hardlink must preserve old import") {
            _ = try await linkedWriteFailure.importFileAsync(at: aliasURL, sourceID: "linked-write-B", mediaType: "public.plain-text")
        }
        expect(linkedWriteFailure.readable && linkedWriteFailure.artifacts == [linkedWriteRetained] && (try! Data(contentsOf: managed(linkedWriteFailure, linkedWriteRetained))) == originalBytes,
               "metadata failure never removes the earlier linked inode or changes durable provenance")
        expect((try! FileManager.default.contentsOfDirectory(at: linkedWriteFailure.url.deletingLastPathComponent().appendingPathComponent("original-files"), includingPropertiesForKeys: nil)).count == 1, "metadata failure removes only its private newly linked path")

        let afterFault = FaultState(), afterFailure = fixture(io: faultIO(afterFault))
        let afterArtifact = try afterFailure.importFile(at: aURL, sourceID: "after-write", mediaType: "public.plain-text")
        afterFault.failAfterWrite = true
        try afterFailure.deleteUnreferenced(id: afterArtifact.id, referencedBySavedPlans: [])
        expect(afterFailure.readable && afterFailure.artifacts.isEmpty && !FileManager.default.fileExists(atPath: managed(afterFailure, afterArtifact).path), "throw after atomic metadata commit uses durable readback and finishes physical cleanup")

        let cleanupFault = FaultState(), cleanupFailure = fixture(io: faultIO(cleanupFault))
        let cleanupArtifact = try cleanupFailure.importFile(at: aURL, sourceID: "cleanup", mediaType: "public.plain-text")
        cleanupFault.failTrashRemoval = true
        rejected("persistent trash removal failure preserves recovery intent") { try cleanupFailure.deleteUnreferenced(id: cleanupArtifact.id, referencedBySavedPlans: []) }
        expect(!cleanupFailure.readable && FileManager.default.fileExists(atPath: cleanupFailure.url.appendingPathExtension("deletion.json").path), "incomplete cleanup fails closed with durable intent")
        let cleanupRestart = FileTransferStore(url: cleanupFailure.url)
        expect(cleanupRestart.readable && cleanupRestart.artifacts.isEmpty && !FileManager.default.fileExists(atPath: cleanupFailure.url.appendingPathExtension("deletion.json").path), "restart finishes already committed deletion and clears intent")

        struct CrashIntent: Encodable { var version = 1; var id: UUID; var artifact: FileTransferArtifact }
        func simulateCrash(_ store: FileTransferStore, artifact: FileTransferArtifact, moved: Bool, committed: Bool) throws {
            let intent = CrashIntent(id: UUID(), artifact: artifact)
            try JSONEncoder().encode(intent).write(to: store.url.appendingPathExtension("deletion.json"), options: .atomic)
            if moved {
                let trashRoot = store.url.deletingLastPathComponent().appendingPathComponent("file-library-trash")
                try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: managed(store, artifact).deletingLastPathComponent(), to: trashRoot.appendingPathComponent(intent.id.uuidString))
            }
            if committed {
                var raw = try JSONSerialization.jsonObject(with: store.exportData()) as! [String: Any]
                raw["artifacts"] = []; raw["library"] = ["version": 1, "archives": []]
                try JSONSerialization.data(withJSONObject: raw).write(to: store.url, options: .atomic)
            }
        }
        for moved in [false, true] {
            let crash = fixture()
            let value = try crash.importFile(at: aURL, sourceID: "crash-before-commit", mediaType: "public.plain-text")
            try crash.archive(id: value.id)
            try simulateCrash(crash, artifact: value, moved: moved, committed: false)
            let restart = FileTransferStore(url: crash.url)
            expect(restart.readable && restart.artifacts == [value] && restart.isArchived(id: value.id), "restart before metadata commit restores old source and archive (moved=\(moved))")
            expect(try! Data(contentsOf: managed(restart, value)) == originalBytes, "restart rollback restores every original byte")
        }
        let committedCrash = fixture()
        let committedArtifact = try committedCrash.importFile(at: aURL, sourceID: "crash-after-commit", mediaType: "public.plain-text")
        try simulateCrash(committedCrash, artifact: committedArtifact, moved: true, committed: true)
        let committedRestart = FileTransferStore(url: committedCrash.url)
        expect(committedRestart.readable && committedRestart.artifacts.isEmpty, "restart after metadata commit finishes deletion rather than resurrecting artifact")

        let legacy = fixture()
        let legacyArtifact = try legacy.importFile(at: aURL, sourceID: "legacy-source", mediaType: "public.plain-text")
        var oldJSON = try JSONSerialization.jsonObject(with: legacy.exportData()) as! [String: Any]
        oldJSON.removeValue(forKey: "library")
        try JSONSerialization.data(withJSONObject: oldJSON).write(to: legacy.url, options: .atomic)
        let migrated = FileTransferStore(url: legacy.url)
        expect(migrated.readable && migrated.archives.isEmpty && migrated.artifacts == [legacyArtifact], "Build 74 JSON without library metadata loads without changing artifacts")
        for field in ["sourceID", "filename", "mediaType", "byteCount", "sha256", "relativePath", "importedAt"] {
            var changed = legacyArtifact
            switch field {
            case "sourceID": changed.sourceID += "-changed"
            case "filename": changed.filename = "different.txt"; changed.relativePath = changed.id.uuidString + "/" + changed.filename
            case "mediaType": changed.mediaType = "public.data"
            case "byteCount": changed.byteCount += 1
            case "sha256": changed.sha256 = String(repeating: "f", count: 64)
            case "relativePath": changed.filename = "elsewhere.txt"; changed.relativePath = changed.id.uuidString + "/" + changed.filename
            default: changed.importedAt = changed.importedAt.addingTimeInterval(1)
            }
            let changedReceipt = receipt([changed])
            try changed.validate(); try changedReceipt.validate(); checks += 2
            rejected("transaction-local UUID index still rejects full artifact inequality: \(field)") { try migrated.put(changedReceipt) }
            expect(migrated.readable && migrated.operations.isEmpty && migrated.artifacts == [legacyArtifact], "mismatched manifest cannot change committed library: \(field)")
        }
        var duplicateJSON = try JSONSerialization.jsonObject(with: migrated.exportData()) as! [String: Any]
        let rawArtifacts = duplicateJSON["artifacts"] as! [[String: Any]]
        duplicateJSON["artifacts"] = rawArtifacts + rawArtifacts
        try JSONSerialization.data(withJSONObject: duplicateJSON).write(to: migrated.url, options: .atomic)
        expect(!FileTransferStore(url: migrated.url).readable, "duplicate artifact UUIDs are rejected before dictionary construction, rather than trapping")
        let badJournal = fixture()
        let retained = try badJournal.importFile(at: aURL, sourceID: "journal-corrupt", mediaType: "public.plain-text")
        try Data("broken deletion journal".utf8).write(to: badJournal.url.appendingPathExtension("deletion.json"))
        let blocked = FileTransferStore(url: badJournal.url)
        expect(!blocked.readable && (try! Data(contentsOf: managed(badJournal, retained))) == originalBytes, "corrupt deletion journal preserves bytes and fails closed")

        let symlinkStore = fixture()
        let symlinkArtifact = try symlinkStore.importFile(at: aURL, sourceID: "symlink-trash", mediaType: "public.plain-text")
        try FileManager.default.createSymbolicLink(at: symlinkStore.url.deletingLastPathComponent().appendingPathComponent("file-library-trash"),
                                                   withDestinationURL: aURL.deletingLastPathComponent())
        rejected("trash symlink must not redirect deletion to an outside directory") { try symlinkStore.deleteUnreferenced(id: symlinkArtifact.id, referencedBySavedPlans: []) }
        expect(symlinkStore.artifacts == [symlinkArtifact] && (try! Data(contentsOf: managed(symlinkStore, symlinkArtifact))) == originalBytes && (try! Data(contentsOf: aURL)) == originalBytes,
               "invalid trash directory leaves managed original and outside source untouched")
        let emptyStats = try fixture().storageStatistics()
        expect(emptyStats.complete && emptyStats.artifactCount == 0 && emptyStats.uniqueStoredFileBytes == 0 && emptyStats.hardLinkSavingsBytes == 0,
               "empty library is a verified zero rather than an unavailable measurement")

        var reviewOperation = receipt([legacyArtifact])
        let reviewedAt = reviewOperation.updatedAt
        reviewOperation.humanReviews = [.init(id: UUID(), artifactIDs: [legacyArtifact.id], resolution: .stillUnknown, detail: "用户记录，未知仍保留", reviewedAt: reviewedAt)]
        try reviewOperation.validate(); checks += 1
        var badReview = reviewOperation
        badReview.humanReviews![0].artifactIDs = [UUID()]
        rejected("human review must refer only to original manifest") { try badReview.validate() }
        badReview = reviewOperation; badReview.humanReviews!.append(badReview.humanReviews![0])
        rejected("human review IDs are unique append-only findings") { try badReview.validate() }
        badReview = reviewOperation; badReview.humanReviews![0].reviewedAt = reviewedAt.addingTimeInterval(1)
        rejected("human review cannot postdate its operation checkpoint") { try badReview.validate() }
        print("FileLibrary: \(checks) real-file content reuse/archive/deletion/recovery checks passed (temporary fixtures only)")
    }
}
